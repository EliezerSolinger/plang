# a struct crosses when every field crosses; a file is not the receiver's to
# have (34.3/74.2)
struct Job:
    name: str
    log: file


def worker(n: int) -> Job:
    return Job("x", open("/dev/null", "w"))


w = spawn(worker, (1,))
print(await w.recv())
