#!/usr/bin/env python3
"""Launch an explicitly selected temporary VM in the local acceptance app."""

import argparse
import getpass
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("workspace", type=Path)
    parser.add_argument(
        "--scenario",
        choices=["lifecycle", "input-latency", "continuous-input", "observe", "displays", "stability", "ime"],
        default="lifecycle",
    )
    parser.add_argument("--password-stdin", action="store_true")
    parser.add_argument("--trace-input", action="store_true", help="Record local key-code ordering, without text, in the temporary harness log")
    args = parser.parse_args()
    try:
        workspace = args.workspace.resolve(strict=True)
        app = args.app.resolve(strict=True)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        parser.error(str(error))

    temporary_roots = [Path("/tmp").resolve(), Path(tempfile.gettempdir()).resolve()]
    if not any(root in workspace.parents for root in temporary_roots):
        parser.error("Only temporary workspaces are allowed")
    if not (workspace / "Workspace/Configuration.json").is_file():
        parser.error("An existing acceptance workspace is required")
    if info.get("RiftVMAcceptanceHarness") is not True:
        parser.error("Use the local-only acceptance app")
    running = subprocess.run(["pgrep", "-x", "RiftVM"], stdout=subprocess.DEVNULL)
    if running.returncode == 0:
        parser.error("Quit running RiftVM instances before starting the isolated harness")
    if running.returncode != 1:
        parser.error("Unable to verify that RiftVM is stopped")
    diagnostics = workspace / "Diagnostics"
    if diagnostics.exists() and any(diagnostics.iterdir()):
        parser.error("Archive existing Diagnostics before starting a fresh acceptance run")

    password = input() if args.password_stdin else getpass.getpass("Temporary VM password: ")
    environment = {key: value for key, value in os.environ.items() if not key.startswith("RIFTVM_")}
    environment.update(
        RIFTVM_OMARCHY_ACCEPTANCE="1",
        RIFTVM_OMARCHY_ACCEPTANCE_WORKSPACE_ROOT=str(workspace),
        RIFTVM_OMARCHY_ACCEPTANCE_UNLOCK_PASSWORD=password,
        RIFTVM_OMARCHY_ACCEPTANCE_SCENARIO=args.scenario,
    )
    if args.trace_input:
        environment["RIFTVM_OMARCHY_TRACE_INPUT_EVENTS"] = "1"
        environment["RIFTVM_INPUT_LATENCY_TRACE"] = "1"
    scenario_flags = {
        "input-latency": "RIFTVM_OMARCHY_INPUT_LATENCY_ACCEPTANCE",
        "continuous-input": "RIFTVM_OMARCHY_CONTINUOUS_INPUT_ACCEPTANCE",
    }
    if args.scenario in scenario_flags:
        environment[scenario_flags[args.scenario]] = "1"
    log = workspace / "Diagnostics" / ("harness-" + args.scenario + ".log")
    log.parent.mkdir(exist_ok=True)
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    with log.open("wb") as output:
        child = subprocess.Popen(
            [str(executable)], env=environment, stdout=output, stderr=output,
            start_new_session=True,
        )
    print("Harness PID:", child.pid, "Scenario:", args.scenario, "Workspace:", workspace)
    print("Start only the named temporary workspace in the Control Center. Log:", log)


if __name__ == "__main__":
    main()
