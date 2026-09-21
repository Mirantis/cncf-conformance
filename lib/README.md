# lib

Shell helpers sourced by `run.sh`, every provisioner and every suite.

Planned: `common.sh` with `log`, `stage` (runs a function, records name, seconds and exit code to `debug/timings.csv`), `wait_for` (poll with timeout) and argument parsing shared by the stage scripts.

Nothing here may know about a specific product or suite.
