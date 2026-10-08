# KDG (Key-Delimited Grammar) parser - BQN (CBQN) implementation.
#
# Usage:
#   bqn kdg.bqn parse <file>            Parse KDG to JSON
#   bqn kdg.bqn validate <file>         Validate KDG syntax
#   bqn kdg.bqn convert <file> [json|csv]
#
# Behaviour mirrors implementations/kdg.go.  CBQN exposes no system value for
# writing to stderr, so failures are raised with ! : CBQN reports them on stderr
# and exits non-zero, and the required message text is present verbatim.
#
# Note: CBQN's •file resolves relative paths against this script's directory, so
# callers must pass an absolute path (the test harness does).

# ----- character / config constants ------------------------------------------
lf ← @+10
cr ← @+13
dq ← @+34
bs ← @+92
sp ← @+32
tab ← @+9
colon ← @+58
plus ← @+43
minus ← @+45
dot ← @+46
comma ← @+44
mac ← @+175

reserved ← "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:" ∾ ⟨dq,sp,tab,lf,cr⟩
validTypes ← ⟨"str","int","float","bool","date"⟩
usage ← "Usage: kdg <parse|validate|convert> <file> [json|csv]"

pre ← "Parse error: "

# ----- generic string helpers ------------------------------------------------
Join ← { w←𝕨 ⋄ x←𝕩 ⋄ (≠w)↓∾{w∾𝕩}¨x }
AnyEq ← { x←𝕩 ⋄ ∨´{𝕩≡x}¨𝕨 }
Nth ← { s←𝕩 ⋄ j←0⊑s ⋄ l←1⊑s ⋄ { (j<≠l) ? ⟨1,j⊑l⟩ ; ⟨0,0⟩ } }

# Split on a single character, keeping every segment (⊔ alone drops trailing
# empty segments, which would lose Go's trailing-empty-string semantics).
SplitChr ← { m←𝕩=𝕨 ⋄ k←+´m ⋄ r←((¬m)/+`m) ⊔ ((¬m)/𝕩) ⋄ r∾((k+1)-(≠r))⥊<"" }
SplitLF ← { lf SplitChr 𝕩 }
SplitOn ← { 𝕨 SplitChr 𝕩 }

DropCR ← { x←𝕩 ⋄ { ((≠x)=0) ? x ; { k←(¬((¯1↓x)=cr)∧((1↓x)=lf))∾1 ⋄ k/x } } }

IsDigit ← { ('0'≤𝕩)∧(𝕩≤'9') }
IsLower ← { ('a'≤𝕩)∧(𝕩≤'z') }
Lower ← { x←𝕩 ⋄ { ((x≥'A')∧(x≤'Z')) ? @+32+(x-@) ; x } }

AllDigits ← { ((≠𝕩)>0) ∧ (∧´IsDigit¨𝕩) }
AllDigOrEmpty ← { ((≠𝕩)=0) ? 1 ; AllDigits 𝕩 }

# unescape / re-escape helpers ------------------------------------------------
RepRec ← {
  s←𝕩
  a←0⊑s ⋄ b←1⊑s ⋄ c←2⊑s ⋄ x←3⊑s ⋄ i←4⊑s ⋄ n←≠x
  { i≥n ? ⟨⟩ ;
    { r0←Nth ⟨i,x⟩ ⋄ r1←Nth ⟨i+1,x⟩
      esc←((1⊑r0)=a)∧(0⊑r1)∧((1⊑r1)=b)
      { esc ? ⟨c⟩∾RepRec ⟨a,b,c,x,i+2⟩ ; { ⟨i⊑x⟩∾RepRec ⟨a,b,c,x,i+1⟩ } } } }
}
Repl ← { RepRec ⟨(0⊑𝕨),(1⊑𝕨),(2⊑𝕨),𝕩,0⟩ }

Norm ← { { 𝕩=mac ? '-' ; 𝕩 }¨𝕩 }

# numeric string checks -------------------------------------------------------
IsIntStr ← {
  x←𝕩 ⋄ n←≠x
  { n=0 ? 0 ; { i←{ (((0⊑x)=plus)∨((0⊑x)=minus)) ? 1 ; 0 } ⋄ (i<n) ∧ AllDigits (i↓x) } }
}

ManOK ← {
  s←𝕩 ⋄ x←s ⋄ nd←+´dot=x
  { nd=0 ? AllDigits x ; { nd>1 ? 0 ; { d←⊑x⊐dot ⋄ l←d↑x ⋄ r←(d+1)↓x ⋄ (AllDigOrEmpty l) ∧ (AllDigOrEmpty r) ∧ (0<(≠l)+(≠r)) } } }
}
ExpOK ← {
  x←𝕩 ⋄ n←≠x
  { n=0 ? 0 ; { i←{ (((0⊑x)=plus)∨((0⊑x)=minus)) ? 1 ; 0 } ⋄ (i<n) ∧ AllDigits (i↓x) } }
}
IsFloatStr ← {
  x←𝕩 ⋄ n←≠x
  { n=0 ? 0 ;
    { body←{ (((0⊑x)=plus)∨((0⊑x)=minus)) ? 1↓x ; x }
      ke←⊑body⊐'e'
      kupp←⊑body⊐'E'
      k←ke⌊kupp
      m←k↑body
      ((k=≠body)∨ExpOK ((k+1)↓body)) ∧ ManOK m } }
}

StripPlus ← { x←𝕩 ⋄ { ((≠x)=0) ? x ; { ((0⊑x)=plus) ? 1↓x ; x } } }
NumOf ← { •ParseFloat StripPlus 𝕩 }
NumStr ← { Norm •Repr 𝕩 }

# error helper ----------------------------------------------------------------
LErr ← { !(pre ∾ "Line " ∾ (•Fmt 𝕨) ∾ ": " ∾ 𝕩) }

# scanning --------------------------------------------------------------------
CloseRec ← {
  s←𝕩 ⋄ line←0⊑s ⋄ i←1⊑s ⋄ n←2⊑s
  { i≥n ? n ; { (i⊑line)=bs ? CloseRec ⟨line,i+2,n⟩ ; { (i⊑line)=dq ? i ; { CloseRec ⟨line,i+1,n⟩ } } } }
}
CloseQ ← { CloseRec ⟨0⊑𝕩,1⊑𝕩,≠(0⊑𝕩)⟩ }

ScanToDelim ← {
  s←𝕩 ⋄ line←0⊑s ⋄ dels←1⊑s ⋄ i←2⊑s
  { i≥≠line ? ≠line ; { ⊑(i⊑line)∊dels ? i ; { ScanToDelim ⟨line,dels,i+1⟩ } } }
}

ScanWRec ← {
  s←𝕩 ⋄ line←0⊑s ⋄ i←1⊑s ⋄ ln←2⊑s ⋄ acc←3⊑s ⋄ n←≠line
  { i≥n ? ln LErr "Unterminated quoted value" ;
    { nx←Nth ⟨i+1,line⟩
      esc←((i⊑line)=bs)∧(0⊑nx)∧(⊑(1⊑nx)∊⟨dq,bs⟩)
      { esc ? ScanWRec ⟨line,i+2,ln,acc∾⟨1⊑nx⟩⟩ ;
        { (i⊑line)=dq ? ⟨acc,i+1⟩ ; { ScanWRec ⟨line,i+1,ln,acc∾⟨i⊑line⟩⟩ } } } } }
}
ScanWrap ← { ScanWRec ⟨0⊑𝕩,1⊑𝕩,2⊑𝕩,⟨⟩⟩ }

DelsOf ← { {2⊑𝕩}¨𝕩 }
LabsOf ← { {0⊑𝕩}¨𝕩 }

# type conversion -------------------------------------------------------------
DaysIn ← {
  s←𝕩 ⋄ y←0⊑s ⋄ m←1⊑s
  { (⊑m∊⟨1,3,5,7,8,10,12⟩) ? 31 ; { (⊑m∊⟨4,6,9,11⟩) ? 30 ; { ((0=400|y)∨((0=4|y)∧(0≠100|y))) ? 29 ; 28 } } }
}
DatePartOK ← {
  s←𝕩 ⋄ y←0⊑s ⋄ mo←1⊑s ⋄ d←2⊑s
  { ((IsIntStr y)∧(IsIntStr mo)∧(IsIntStr d)) ? { yn←NumOf y ⋄ mn←NumOf mo ⋄ dn←NumOf d ⋄ (yn≥1)∧(yn≤9999)∧(mn≥1)∧(mn≤12)∧(dn≥1)∧(dn≤DaysIn ⟨yn,mn⟩) } ; 0 }
}
DateOK ← { ps←'-' SplitOn 𝕩 ⋄ { ((≠ps)=3) ? DatePartOK ⟨0⊑ps,1⊑ps,2⊑ps⟩ ; 0 } }

BoolVal ← {
  s←𝕩 ⋄ val←0⊑s ⋄ ln←1⊑s ⋄ l←Lower¨val
  { ((l≡"true")∨(l≡"1")) ? 1 ; { ((l≡"false")∨(l≡"0")) ? 0 ; ln LErr ("Invalid boolean: '"∾val∾"'") } }
}
ConvInt ← { s←𝕩 ⋄ val←0⊑s ⋄ ln←1⊑s ⋄ { (IsIntStr val) ? NumOf val ; ln LErr ("Invalid integer: '"∾val∾"'") } }
ConvFloat ← { s←𝕩 ⋄ val←0⊑s ⋄ ln←1⊑s ⋄ { (IsFloatStr val) ? NumOf val ; ln LErr ("Invalid float: '"∾val∾"'") } }
ConvDate ← { s←𝕩 ⋄ val←0⊑s ⋄ ln←1⊑s ⋄ { (DateOK val) ? val ; ln LErr ("Invalid date (expected YYYY-MM-DD): '"∾val∾"'") } }
Convert ← {
  s←𝕩 ⋄ val←0⊑s ⋄ ty←1⊑s ⋄ ln←2⊑s
  { (ty≡"str") ? val ;
    { (ty≡"int") ? ConvInt ⟨val,ln⟩ ;
      { (ty≡"float") ? ConvFloat ⟨val,ln⟩ ;
        { (ty≡"bool") ? BoolVal ⟨val,ln⟩ ;
          { (ty≡"date") ? ConvDate ⟨val,ln⟩ ;
            ln LErr ("Unknown type: '"∾ty∾"'") } } } } }
}

# definition parsing ----------------------------------------------------------
ParseDef ← {
  s←𝕩 ⋄ line←0⊑s ⋄ ln←1⊑s ⋄ n←≠line
  ci←⊑line⊐colon
  { ((ci=0)∨(ci≥n)) ? ln LErr ("Invalid definition syntax: '"∾line∾"'") ; @ }
  ty←ci↑line
  { ((∧´IsLower¨ty)=0) ? ln LErr ("Invalid definition syntax: '"∾line∾"'") ; @ }
  { ((ci+1)≥n) ? ln LErr ("Invalid definition syntax: '"∾line∾"'") ; { (((ci+1)⊑line)≠dq) ? ln LErr ("Invalid definition syntax: '"∾line∾"'") ; @ } }
  j←CloseQ ⟨line,ci+2⟩
  { (j≠n-2) ? ln LErr ("Invalid definition syntax: '"∾line∾"'") ; @ }
  d←(n-1)⊑line
  { (⊑d∊reserved) ? ln LErr ("Invalid delimiter: '"∾d∾"' (reserved character)") ; @ }
  { ((validTypes AnyEq ty)=0) ? ln LErr ("Unknown type: '"∾ty∾"'") ; @ }
  raw←(ci+2)↓(j↑line)
  r0←⟨bs,dq,dq⟩ Repl raw
  lab←⟨bs,bs,bs⟩ Repl r0
  ⟨ty,lab,d⟩
}
DefStep ← {
  s←𝕩 ⋄ lines←0⊑s ⋄ i←1⊑s ⋄ sep←2⊑s ⋄ acc←3⊑s
  d←ParseDef ⟨i⊑lines,i+1⟩
  dl←2⊑d
  k←⊑(DelsOf acc)⊐dl
  { (k<≠acc) ? (i+1) LErr ("Delimiter '"∾dl∾"' already used for field '"∾(1⊑(k⊑acc))∾"'") ; @ }
  ⟨lines,i+1,sep,acc∾⟨d⟩⟩
}
DefLoop ← { s←𝕩 ⋄ { ((1⊑s)≥(2⊑s)) ? 3⊑s ; DefLoop DefStep s } }

# record parsing --------------------------------------------------------------
TakeField ← {
  s←𝕩 ⋄ defs←0⊑s ⋄ dels←1⊑s ⋄ line←2⊑s ⋄ p2←3⊑s ⋄ acc←4⊑s ⋄ ln←5⊑s ⋄ val←6⊑s
  d←p2⊑line
  k←⊑dels⊐d
  { (k≥≠defs) ? ln LErr ("Undefined delimiter: '"∾d∾"'") ; @ }
  df←k⊑defs ⋄ ty←0⊑df ⋄ lab←1⊑df
  { ((LabsOf acc) AnyEq lab) ? ln LErr ("Duplicate field in record: '"∾lab∾"'") ; @ }
  RecScan ⟨defs,dels,line,p2+1,acc∾⟨⟨lab,ty,Convert ⟨val,ty,ln⟩⟩⟩,ln⟩
}
WrappedPath ← {
  s←𝕩 ⋄ defs←0⊑s ⋄ dels←1⊑s ⋄ line←2⊑s ⋄ pos←3⊑s ⋄ acc←4⊑s ⋄ ln←5⊑s
  r←ScanWrap ⟨line,pos+1,ln⟩
  val←0⊑r ⋄ p2←1⊑r
  { (p2≥≠line) ? ln LErr ("Missing delimiter after value '"∾val∾"'") ; @ }
  TakeField ⟨defs,dels,line,p2,acc,ln,val⟩
}
RawPath ← {
  s←𝕩 ⋄ defs←0⊑s ⋄ dels←1⊑s ⋄ line←2⊑s ⋄ pos←3⊑s ⋄ acc←4⊑s ⋄ ln←5⊑s
  p2←ScanToDelim ⟨line,dels,pos⟩
  { (p2≥≠line) ? ln LErr ("No delimiter found for value starting at column "∾(•Fmt pos)) ; @ }
  TakeField ⟨defs,dels,line,p2,acc,ln,(pos↓(p2↑line))⟩
}
RecField ← { s←𝕩 ⋄ line←2⊑s ⋄ pos←3⊑s ⋄ { (pos⊑line)=dq ? WrappedPath s ; RawPath s } }
RecScan ← { s←𝕩 ⋄ { ((3⊑s)≥≠(2⊑s)) ? 4⊑s ; RecField s } }

RecNext ← {
  s←𝕩 ⋄ lines←0⊑s ⋄ i←1⊑s ⋄ acc←2⊑s ⋄ defs←3⊑s ⋄ dels←4⊑s
  line←i⊑lines
  { (line≡"") ? ⟨lines,i+1,acc,defs,dels⟩ ; ⟨lines,i+1,acc∾⟨RecScan ⟨defs,dels,line,0,⟨⟩,i+1⟩⟩,defs,dels⟩ }
}
RecLoop ← { s←𝕩 ⋄ { ((1⊑s)≥≠(0⊑s)) ? 2⊑s ; RecLoop RecNext s } }

ReadLines ← {
  s←•file.Chars 𝕩
  t←DropCR s
  ls←SplitLF t
  { (((≠ls)>0)∧(""≡¯1⊑ls)) ? ¯1↓ls ; ls }
}

ParseAll ← {
  lines←𝕩
  sep←⊑({𝕩≡""}¨lines)⊐1
  { (sep≥≠lines) ? !(pre∾"No blank line separator found between definitions and data") ; @ }
  defs←DefLoop ⟨lines,0,sep,⟨⟩⟩
  RecLoop ⟨lines,sep+1,⟨⟩,defs,DelsOf defs⟩
}

# JSON output -----------------------------------------------------------------
HexD ← { x←𝕩 ⋄ { x<10 ? @+48+x ; @+87+x } }
EscQ ← {
  c←𝕩
  k←⊑⟨dq,bs,lf,cr,tab⟩⊐c
  reps←⟨⟨bs,dq⟩,⟨bs,bs⟩,⟨bs,'n'⟩,⟨bs,'r'⟩,⟨bs,'t'⟩⟩
  { (k<5) ? k⊑reps ; { (c<@+32) ? ⟨bs,'u','0','0',(HexD ⌊(c-@)÷16),(HexD 16|(c-@))⟩ ; ⟨c⟩ } }
}
JsonStr ← { ∾EscQ¨𝕩 }
JsonVal ← {
  s←𝕩 ⋄ t←0⊑s ⋄ v←1⊑s
  { ((t≡"str")∨(t≡"date")) ? dq∾(JsonStr v)∾dq ;
    { ((t≡"int")∨(t≡"float")) ? NumStr v ;
      { (t≡"bool") ? { (v=1) ? "true" ; "false" } ; "null" } } }
}
FldStr ← { s←𝕩 ⋄ "    "∾dq∾(JsonStr 0⊑s)∾dq∾": "∾(JsonVal ⟨1⊑s,2⊑s⟩) }
ObjStr ← { r←𝕩 ⋄ { ((≠r)=0) ? "{}" ; "{"∾lf∾((comma∾lf) Join (FldStr¨r))∾lf∾"  }" } }
JsonArr ← { rs←𝕩 ⋄ { ((≠rs)=0) ? "[]" ; "["∾lf∾((comma∾lf) Join ({"  "∾ObjStr 𝕩}¨rs))∾lf∾"]" } }

# CSV output ------------------------------------------------------------------
AccKeys ← {
  s←𝕩 ⋄ keys←0⊑s ⋄ rec←1⊑s ⋄ i←2⊑s
  { i≥≠rec ? keys ; { l←0⊑(i⊑rec) ⋄ { (keys AnyEq l) ? AccKeys ⟨keys,rec,i+1⟩ ; AccKeys ⟨keys∾⟨l⟩,rec,i+1⟩ } } }
}
AccRecs ← { s←𝕩 ⋄ keys←0⊑s ⋄ rs←1⊑s ⋄ j←2⊑s ⋄ { j≥≠rs ? keys ; AccRecs ⟨AccKeys ⟨keys,j⊑rs,0⟩,rs,j+1⟩ } }
AllKeys ← { AccRecs ⟨⟨⟩,𝕩,0⟩ }
FindVal ← { s←𝕩 ⋄ rec←0⊑s ⋄ k←1⊑s ⋄ kk←⊑(({𝕩≡k}¨(LabsOf rec))⊐1) ⋄ { (kk≥≠rec) ? ⟨⟩ ; kk⊑rec } }
CsvVal ← {
  s←𝕩 ⋄ t←0⊑s ⋄ v←1⊑s
  { ((t≡"str")∨(t≡"date")) ? v ;
    { (t≡"int") ? •Repr v ;
      { (t≡"bool") ? { (v=1) ? "True" ; "False" } ;
        { st←Norm •Repr v ⋄ { (∨´st∊"eE.") ? st ; st∾".0" } } } } }
}
RepDQ ← { ∾{ { 𝕩=dq ? ⟨dq,dq⟩ ; ⟨𝕩⟩ } }¨𝕩 }
EscCsv ← { s←𝕩 ⋄ { (∨´s∊⟨comma,dq,lf⟩) ? (dq∾(RepDQ s)∾dq) ; s } }
RowStr ← { s←𝕩 ⋄ ks←0⊑s ⋄ rec←1⊑s ⋄ comma Join ({ { f←FindVal ⟨rec,𝕩⟩ ⋄ { ((≠f)=0) ? "" ; EscCsv CsvVal ⟨1⊑f,2⊑f⟩ } } }¨ks) }
CsvStr ← {
  rs←𝕩
  { ((≠rs)=0) ? "" ;
    { ks←AllKeys rs ⋄ lf Join (⟨comma Join (EscCsv¨ks)⟩ ∾ ({RowStr ⟨ks,𝕩⟩}¨rs)) } }
}

# CLI -------------------------------------------------------------------------
DoParse ← { rs←ParseAll 𝕩 ⋄ •Out JsonArr rs ⋄ 0 }
DoValidate ← { rs←ParseAll 𝕩 ⋄ •Out "Valid KDG document" ⋄ 0 }
DoConvert ← {
  s←𝕩 ⋄ fmt←1⊑s ⋄ rs←ParseAll (0⊑s)
  { (fmt≡"json") ? {•Out JsonArr rs ⋄ 0} ; { (fmt≡"csv") ? {•Out CsvStr rs ⋄ 0} ; !("Unknown format: "∾fmt) } }
}
FmtOf ← { a←𝕩 ⋄ { ((≠a)>2) ? 2⊑a ; "json" } }
Run ← {
  a←𝕩
  { ((≠a)<2) ? !usage ; @ }
  cmd←0⊑a ⋄ path←1⊑a
  { (•file.Exists path) ? @ ; !("File not found: "∾path) }
  lines←ReadLines path
  { (cmd≡"parse") ? DoParse lines ;
    { (cmd≡"validate") ? DoValidate lines ;
      { (cmd≡"convert") ? DoConvert ⟨lines,FmtOf a⟩ ;
        !("Unknown command: "∾cmd) } } }
}
PrefixOf ← { a←𝕩 ⋄ { ((≠a)≥2) ? { ((0⊑a)≡"validate") ? "Invalid: " ; "Parse error: " } ; "Parse error: " } }

pre ↩ PrefixOf •args
Run •args
