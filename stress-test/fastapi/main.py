from fastapi import FastAPI, Query
from threading import Thread
import time, os

app = FastAPI()

def burn_cpu(cores: int, duration: int):
    def _burn():
        x = 0
        while time.time() < end_time:
            x ^= 1  # keep CPU busy
    end_time = time.time() + duration
    threads = []
    for _ in range(cores):
        t = Thread(target=_burn)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()

def allocate_ram(gb: int, duration: int):
    try:
        data = [' ' * 1024 * 1024] * (gb * 1024)  # allocate RAM in MB
        time.sleep(duration)
    except MemoryError:
        return "MemoryError: Requested more RAM than available"
    finally:
        del data

@app.get("/healthcheck")
def healthcheck():
    return {"status": "ok"}

@app.get("/stress/cpu")
def stress_cpu(cores: int = Query(..., ge=1), duration: int = Query(30, ge=1)):
    Thread(target=burn_cpu, args=(cores, duration)).start()
    return {"message": f"Started CPU stress on {cores} core(s) for {duration}s"}

@app.get("/stress/ram")
def stress_ram(gb: int = Query(..., ge=1), duration: int = Query(30, ge=1)):
    Thread(target=allocate_ram, args=(gb, duration)).start()
    return {"message": f"Started RAM stress for {gb}GB for {duration}s"}
