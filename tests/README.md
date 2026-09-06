# Firmware guard regression checks

Run in a disposable Linux container; the suite reads `/proc`, creates processes and mocks router operations. The repository is mounted read-only and networking is disabled. No daemon binaries, router connection or third-party Python packages are needed.

```sh
docker run --rm --network none --name awg-guards-125 \
  -e AWG_TEST_ISOLATED=1 -v "$PWD:/src:ro" \
  --entrypoint /bin/sh busybox:1.25 /src/tests/firmware-guards.sh
docker run --rm --network none --name awg-guards-131 \
  -e AWG_TEST_ISOLATED=1 -v "$PWD:/src:ro" \
  --entrypoint /bin/sh busybox:1.31 /src/tests/firmware-guards.sh
```

The tests extract the current production function definitions without sourcing the router startup code. They cover bounded calls, cancellation, concurrent sibling output, descendant cleanup, DNS/IPv6 timeout decisions, operation-lock identity and acquisition age, concurrent reclaim/acquire, dead transition guards, firmware without `flock`, deliberate Stop with failed cron removal for both roles, and the elapsed-time rc_service budget.

These checks do not validate real firmware IPC, firewall behavior, ARM daemon builds or a release `.ipk`. The normal release packaging gates remain `build-ipk.sh` and `.github/scripts/check-ipk-owners.sh` with the compiled binaries supplied as in `.github/workflows/release.yml`.
