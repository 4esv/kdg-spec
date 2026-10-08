# Contributing

Please don't.

## Bug Reports

If a parser does not parse, or parses incorrectly, this is usually the specification being followed. Include the input, the expected output, and the actual output, so that the discrepancy can be filed correctly. No action will be taken, but the form will be correct.

## New Implementations

There are nine implementations. The language you are considering has, by now, almost certainly been done, or been deliberately avoided.

If you proceed regardless: the parser must pass all test vectors, follow SPEC.md, have no runtime dependencies, and ship a CLI. Place it in `implementations/` and name it `kdg.{ext}`. This is the procedure. The procedure is not an invitation.

## Pull Requests

Fork, change, test, submit. Reconsider at any point, preferably before submitting.

## Code Style

Match the existing code. Where the existing code is inconsistent, the inconsistency is the style.

## Testing

```bash
python3 tests/run_tests.py
```

It validates every vector, in every parser, so that you do not have to.

## Questions

The FAQ has already answered it.

## Code of Conduct

Be reasonable. Failing that, be brief.
