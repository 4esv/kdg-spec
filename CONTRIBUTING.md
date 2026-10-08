# Contributing

Contributions are accepted.

## Bug Reports

If the parser does not parse, or parses incorrectly, open an issue. Include:

- The input
- The expected output
- The actual output

This is usually sufficient.

## New Implementations

If you write a KDG parser in another language:

1. It must pass all test vectors in `tests/vectors/`
2. It must follow `SPEC.md`
3. It should have no runtime dependencies
4. It should include a CLI

Place it in `implementations/`. Name it `kdg.{ext}`.

## Pull Requests

1. Fork the repository
2. Make changes
3. Ensure tests pass
4. Submit PR

The process is standard.

## Code Style

Match the existing code. If the existing code is inconsistent, pick one style and be consistent with that.

## Testing

```bash
python3 tests/run_tests.py
```

It validates valid vectors. It confirms invalid vectors fail with the error in the adjacent `.expected` sidecar. It validates examples. It does all of this in every parser.

## Questions

Open an issue. Label it appropriately.

## Code of Conduct

Be reasonable.
