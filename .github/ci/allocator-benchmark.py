import json
import os
from pathlib import Path
import platform
import re
import signal
import socket
import statistics
import subprocess
import tempfile
import time


results_dir = Path('allocator-results').resolve()
environment = dict(os.environ, PGHOST='127.0.0.1', PGPORT='16432',
                   PGUSER='allocator_bench', PGPASSWORD='allocator_bench',
                   PGDATABASE='allocator_bench', PGSSLMODE='disable', RUST_LOG='error')
records = []
with tempfile.TemporaryDirectory(prefix='allocator-benchmark-') as directory:
    root = Path(directory)
    (root / 'pgdog.toml').write_text('''[general]
host = "127.0.0.1"
port = 16432
workers = 2
default_pool_size = 32
[[databases]]
name = "allocator_bench"
host = "127.0.0.1"
port = 55432
role = "primary"
''')
    (root / 'users.toml').write_text('''[[users]]
name = "allocator_bench"
database = "allocator_bench"
password = "allocator_bench"
''')
    for workload, protocol, sql in [('select-1', 'simple', 'SELECT 1;'),
                                    ('8k-result', 'prepared', "SELECT repeat('x', 8192);")]:
        query = root / 'query.sql'
        query.write_text(sql)
        for clients in (1, 16):
            for pair in range(4):
                # Alternate AB/BA to reduce bias from host drift and cache warming.
                versions = ('0.6', '0.7') if pair % 2 == 0 else ('0.7', '0.6')
                for version in versions:
                    log_path = results_dir / f'{workload}-{clients}-{pair}-{version}.log'
                    with log_path.open('w') as log:
                        server = subprocess.Popen([str(results_dir / f'pgdog-{version}'),
                                                   '--config', str(root / 'pgdog.toml'),
                                                   '--users', str(root / 'users.toml')],
                                                  stdout=log, stderr=log, env=environment)
                        try:
                            deadline = time.monotonic() + 30
                            while True:
                                try:
                                    with socket.create_connection(('127.0.0.1', 16432), timeout=1):
                                        break
                                except OSError:
                                    assert server.poll() is None and time.monotonic() < deadline
                                    time.sleep(0.05)
                            command = ['pgbench', '-n', '-c', str(clients), '-j', str(min(clients, 2)),
                                       '-M', protocol, '-f', str(query)]
                            subprocess.run(command + ['-T', '3'], env=environment, check=True,
                                           capture_output=True, text=True, timeout=30)
                            trial = subprocess.Popen(command + ['-T', '10'], env=environment,
                                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                                     text=True)
                            rss_kib = 0
                            deadline = time.monotonic() + 45
                            while trial.poll() is None:
                                assert time.monotonic() < deadline, 'pgbench timed out'
                                assert server.poll() is None, 'PgDog exited during measurement'
                                status = Path(f'/proc/{server.pid}/status').read_text()
                                rss_kib = max(rss_kib, int(re.search(r'^VmRSS:\s+(\d+)', status, re.M)[1]))
                                time.sleep(0.1)
                            stdout, stderr = trial.communicate(timeout=5)
                            assert trial.returncode == 0, stderr
                            failed = re.search(r'number of failed transactions:\s+(\d+)', stdout)
                            assert failed is None or int(failed[1]) == 0, stdout
                            record = dict(version=version, workload=workload, protocol=protocol,
                                          clients=clients, pair=pair,
                                          tps=float(re.search(r'tps = ([\d.]+)', stdout)[1]),
                                          latency_ms=float(re.search(r'latency average = ([\d.]+)', stdout)[1]),
                                          peak_rss_kib=rss_kib)
                            records.append(record)
                            print(json.dumps(record), flush=True)
                            (results_dir / 'results.json').write_text(json.dumps({
                                'platform': platform.platform(), 'cpu_count': os.cpu_count(),
                                'duration_seconds': 10, 'warmup_seconds': 3,
                                'records': records}, indent=2))
                        finally:
                            server.send_signal(signal.SIGINT)
                            try:
                                server.wait(timeout=15)
                            except subprocess.TimeoutExpired:
                                server.kill()
                                server.wait(timeout=5)

summary = ['# jemallocator 0.6 vs 0.7', '',
           'Native ARM64, 4 KiB kernel pages; same code, toolchain, PostgreSQL and configuration. '
           'Four alternating pairs per case, 3s warmup and 10s measured runs. '
           'These short CI microbenchmarks do not establish production-wide performance.', '',
           '| Workload | Clients | 0.6 median TPS | 0.7 median TPS | Change | 0.6/0.7 TPS range | 0.6/0.7 median peak RSS KiB |',
           '| --- | ---: | ---: | ---: | ---: | --- | --- |']
for workload in ('select-1', '8k-result'):
    for clients in (1, 16):
        samples = [[r for r in records if r['workload'] == workload and r['clients'] == clients and r['version'] == v]
                   for v in ('0.6', '0.7')]
        medians = [statistics.median(r['tps'] for r in rows) for rows in samples]
        ranges = [f"{min(r['tps'] for r in rows):.0f}–{max(r['tps'] for r in rows):.0f}" for rows in samples]
        rss = [statistics.median(r['peak_rss_kib'] for r in rows) for rows in samples]
        summary.append(f'| {workload} | {clients} | {medians[0]:.0f} | {medians[1]:.0f} | '
                       f'{(medians[1] / medians[0] - 1) * 100:+.1f}% | {ranges[0]} / {ranges[1]} | {rss[0]:.0f} / {rss[1]:.0f} |')
text = '\n'.join(summary) + '\n'
(results_dir / 'summary.md').write_text(text)
if 'GITHUB_STEP_SUMMARY' in os.environ:
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
        output.write(text)
print(text)
