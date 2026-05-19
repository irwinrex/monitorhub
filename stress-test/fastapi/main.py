from fastapi import FastAPI, Request
import threading, time, re, os, tempfile

app = FastAPI()


def parse_cpu(val: str) -> tuple[int, int]:
    if val.endswith("m"):
        return (int(val[:-1]) // 1000, 1)
    cores = int(val)
    return (cores, 30)


def parse_ram(val: str) -> tuple[int, int]:
    m = re.match(r"(\d+)([a-zA-Z]+)", val)
    if not m:
        raise ValueError(f"Invalid RAM format: {val}")
    n, unit = int(m.group(1)), m.group(2).lower()
    factor = {
        "b": 1,
        "kb": 1024,
        "mb": 1024**2,
        "gb": 1024**3,
        "tb": 1024**4,
        "kib": 1024,
        "mib": 1024**2,
        "gib": 1024**3,
        "tib": 1024**4,
    }
    if unit in factor:
        return (factor[unit] // (1024**2), 30)
    raise ValueError(f"Unknown unit: {unit}")


def parse_io(val: str) -> tuple[str, int]:
    m = re.match(r"(\d+)([a-zA-Z]+)", val)
    if not m:
        raise ValueError(f"Invalid I/O format: {val}")
    n, unit = int(m.group(1)), m.group(2).lower()
    factor = {"b": 1, "kb": 1024, "mb": 1024**2, "gb": 1024**3}
    if unit in factor:
        return (str(n) + unit, 30)
    raise ValueError(f"Unknown unit: {unit}")


def burn_cpu(cores: int, duration: int):
    def _burn():
        x = 0
        while time.time() < end_time:
            x ^= 1

    end_time = time.time() + duration
    threads = [threading.Thread(target=_burn) for _ in range(cores)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()


def allocate_ram(mb: int, duration: int):
    try:
        data = [" " * 1024 * 1024] * mb
        time.sleep(duration)
    except MemoryError:
        return "MemoryError"
    finally:
        del data


def burn_io(size_mb: int, duration: int):
    tmp = tempfile.gettempdir()
    filepath = os.path.join(tmp, f"io_stress_{os.getpid()}.tmp")
    chunk = b"x" * (1024 * 1024)
    try:
        end_time = time.time() + duration
        with open(filepath, "wb") as f:
            while time.time() < end_time:
                f.write(chunk)
                f.flush(os.fsync)
                f.seek(0)
    finally:
        if os.path.exists(filepath):
            os.remove(filepath)


@app.get("/stress/healthcheck")
def healthcheck():
    return {"status": "ok"}


@app.get("/stress/cpu/{cores}")
def stress_cpu(cores: str, duration: int = 30):
    c, d = parse_cpu(cores)
    threading.Thread(target=burn_cpu, args=(c, d)).start()
    return {"message": f"Started CPU stress on {c} core(s) for {d}s"}


@app.get("/stress/ram/{gb}")
def stress_ram(gb: str, duration: int = 30):
    mb, d = parse_ram(gb)
    threading.Thread(target=allocate_ram, args=(mb, d)).start()
    return {"message": f"Started RAM stress for {mb}MB for {d}s"}


@app.get("/stress/io/{size}")
def stress_io(size: str, duration: int = 30):
    sz, d = parse_io(size)
    threading.Thread(target=burn_io, args=(int(sz.rstrip("bkmg")), d)).start()
    return {"message": f"Started I/O stress for {sz} for {d}s"}


@app.get("/stress/mtls/test")
def test_mtls(request: Request):
    client_cert = request.client_cert
    return {
        "status": "ok",
        "mtls_verified": client_cert is not None,
        "client_common_name": getattr(client_cert, "subject", None)
        if client_cert
        else None,
    }


@app.get("/stress/secrets/check")
def check_secrets():
    return {"exists": os.path.exists("/mnt/secrets/secrets.json")}
