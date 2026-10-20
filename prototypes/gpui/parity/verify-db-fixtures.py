#!/usr/bin/env python3
"""Check synthetic setup SQL on two owned, unexposed disposable containers.

Images must already be present. No credentials, SQL or results are logged.
This establishes fixture validity, not frontend/native parity or TLS coverage.
"""
import argparse
import json
import os
import pathlib
import secrets
import shutil
import subprocess
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def command(args, timeout=30):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        raise RuntimeError("Fixture command failed; phase identified in summary (SQL/credentials/results suppressed).")
    # Setup SELECTs can contain arbitrary binary data. Their output is never
    # logged; only Docker's textual IDs are consumed by the caller.
    return result.stdout.decode(errors="replace").strip()


def run(engine, image):
    started = time.monotonic()
    result = {"engine": engine, "image": image, "status": "failed", "scope": "synthetic setup SQL and server assertions only"}
    phase = "check-local-image"
    owned_id = None
    temporary = pathlib.Path(tempfile.mkdtemp(prefix="db-fixture-", dir=ROOT / "build/gpui-parity"))
    temporary.chmod(0o700)
    try:
        result["imageID"] = command(["docker", "image", "inspect", "--format", "{{.Id}}", image])
        (temporary / "password").write_text(secrets.token_hex(32), encoding="utf-8")
        (temporary / "password").chmod(0o600)
        shutil.copyfile(HERE / "fixtures" / (engine + ".sql"), temporary / "setup.sql")
        args = ["docker", "run", "--detach", "--rm", "--network", "none", "--mount", f"type=bind,source={temporary},target=/fixtures,readonly"]
        if engine == "postgresql":
            args += ["--env", "POSTGRES_USER=dbeer", "--env", "POSTGRES_DB=dbeer", "--env", "POSTGRES_PASSWORD_FILE=/fixtures/password", image]
            ready = ["pg_isready", "--username", "dbeer", "--dbname", "dbeer"]
            setup = ["psql", "--username", "dbeer", "--dbname", "dbeer", "--no-psqlrc", "--set", "ON_ERROR_STOP=1", "--file", "/fixtures/setup.sql"]
            verify = ["psql", "--username", "dbeer", "--dbname", "dbeer", "--no-psqlrc", "--set", "ON_ERROR_STOP=1", "--command",
                      "DO $$ BEGIN IF (SELECT count(*) FROM dbeer_parity_v1.values_grid) <> 1205 THEN RAISE EXCEPTION 'fixture row count'; END IF; IF (SELECT exact_value::text FROM dbeer_parity_v1.values_grid WHERE id=1) <> '9007199254740993.123456789000000000' THEN RAISE EXCEPTION 'fixture exact numeric'; END IF; END $$;"]
        else:
            args += ["--env", "MYSQL_ROOT_PASSWORD_FILE=/fixtures/password", image, "--log-bin-trust-function-creators=ON", "--local-infile=OFF"]
            prefix = 'MYSQL_PWD="$(cat /fixtures/password)" mysql --user=root --default-character-set=utf8mb4 '
            ready = ["sh", "-ec", prefix + '--execute="SELECT 1"']
            setup = ["sh", "-ec", prefix + '< /fixtures/setup.sql']
            # SIGNAL from a procedure makes wrong setup fail without logging results.
            assertion = "CREATE PROCEDURE dbeer_parity_v1.assert_fixture() BEGIN IF (SELECT COUNT(*) FROM dbeer_parity_v1.values_grid) <> 1005 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='fixture row count'; END IF; IF (SELECT CAST(exact_value AS CHAR) FROM dbeer_parity_v1.values_grid WHERE id=1) <> '9007199254740993.123456789000000000' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='fixture exact numeric'; END IF; END; CALL dbeer_parity_v1.assert_fixture();"
            (temporary / "assert.sql").write_text(assertion, encoding="utf-8")
            verify = ["sh", "-ec", prefix + '< /fixtures/assert.sql']
        phase = "start-owned-container"
        owned_id = command(args)
        phase = "wait-ready"
        deadline = time.monotonic() + 120
        while True:
            attempt = subprocess.run(["docker", "exec", owned_id] + ready, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            if attempt.returncode == 0:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("Owned fixture did not become ready")
            time.sleep(1)
        phase = "execute-setup"
        command(["docker", "exec", owned_id] + setup, timeout=60)
        phase = "assert-row-count-and-exact-numeric"
        if engine == "mysql":
            # The MySQL client needs a delimiter around the compound assertion.
            path = temporary / "assert.sql"
            path.write_text("DELIMITER //\n" + assertion.replace(" END; CALL", " END//\nCALL") + "//\n", encoding="utf-8")
        command(["docker", "exec", owned_id] + verify)
        result["status"] = "passed"
        result["completedSummary"] = f"{engine} synthetic setup and row-count/exact-numeric assertions completed."
    except (OSError, RuntimeError, subprocess.TimeoutExpired):
        result["failurePhase"] = phase
    finally:
        if owned_id:
            try:
                command(["docker", "rm", "--force", owned_id])
            except (OSError, RuntimeError, subprocess.TimeoutExpired):
                result["cleanup"] = "failed; owned container requires removal"
                result["ownedContainerID"] = owned_id
                result["status"] = "failed"
        shutil.rmtree(temporary)
        result["durationSeconds"] = round(time.monotonic() - started, 3)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--postgres-image", default="postgres:17")
    parser.add_argument("--mysql-image", default="mysql:8.4")
    parser.add_argument("--output", default="build/gpui-parity/db-fixtures.json")
    args = parser.parse_args()
    (ROOT / "build/gpui-parity").mkdir(parents=True, exist_ok=True)
    results = [run("postgresql", args.postgres_image), run("mysql", args.mysql_image)]
    output = (ROOT / args.output).resolve()
    if not output.is_relative_to(ROOT / "build"):
        raise ValueError("Output must stay under ignored build/")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"schemaVersion": 1, "results": results, "nativeAcceptance": "not-run", "tls": "not-run"}, indent=2) + "\n", encoding="utf-8")
    os.chmod(output, 0o600)
    for result in results:
        print(result.get("completedSummary", result["engine"] + " failed in phase " + result.get("failurePhase", "cleanup")))
    return 0 if all(result["status"] == "passed" for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
