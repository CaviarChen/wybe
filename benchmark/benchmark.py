import time
import subprocess
from typing import *

def wybe_build_target(target: str, no_multi_specz: bool) -> str:
    TIMEOUT = 5  # sec
    args = ["wybemk", "--force-all"]
    if no_multi_specz:
        args.append("--no-multi-specz")
    args.append(target)

    r = subprocess.run(args, timeout=TIMEOUT, check=True,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return r.stdout.decode("utf-8")

def execute_program(cmd: str) -> Tuple[float, str]:
    time.sleep(1)
    start = time.time()
    r = subprocess.run(cmd, shell=True, check=True,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    end = time.time()
    time_used = end - start
    return (time_used, r.stdout.decode("utf-8"))

def centered_average(nums):
    return (sum(nums) - max(nums) - min(nums)) / (len(nums) - 2) 

def benchmark_program(cmd:str) -> Tuple[List[float], float, str]:
    first_output = None
    time_used_list = []
    for _ in range(5):
        t, output = execute_program(cmd)
        if first_output is None:
            first_output = output
        time_used_list.append(t)
    # average
    avg_time = centered_average(time_used_list)
    return (time_used_list, avg_time, first_output)
    

TARGET = "naive_reverse"
CMD = "./naive_reverse"

for no_multi_specz in [False, True]:
    wybe_build_target(TARGET, no_multi_specz)
    print("="*40)
    if no_multi_specz:
        print("No Multiple Specialization")
    else:
        print("Multiple Specialization")
    print("-"* 40)
    times, avg_time, output = benchmark_program(CMD)
    print("Time Used:", times)
    print("Avg Time:", avg_time)
    print("-"* 40)
    print("Outputs:")
    lines = output.split('\n')
    for l in lines:
        if len(l) <= 1000:
            print(l)
    print("-"* 40)
    print()
    print()

