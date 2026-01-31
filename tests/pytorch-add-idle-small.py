# Copyright (c) 2023 Georgios Alexopoulos
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import torch
import subprocess
import sys
import time

try:
    from tqdm import tqdm
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "tqdm"])
finally:
    from tqdm import tqdm

start_time = time.time()
n = 14000
device = torch.cuda.current_device()
x = torch.ones([n, n], dtype=torch.float32).to(device)
y = torch.ones([n, n], dtype=torch.float32).to(device)

# Reduced iterations to balance the sleep time, keeping total duration reasonable
# but long enough to observe parallel execution.
# 4000 iters * 0.1s sleep = 400s = ~6.5 mins.
# Original was 40000 iters. 
# We want to keep memory usage high (so allocations happen) but compute low.
for i in tqdm(range(4000)):
    z = torch.add(x, y)
    torch.cuda.synchronize()
    # Sleep to simulate idle/low utilization (approx 10 steps per second)
    time.sleep(0.1)

torch.cuda.synchronize()  # Ensure computations are finished
print("PASS")
print("--- %s seconds ---" % (time.time() - start_time))
