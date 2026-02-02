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
    from tqdm import tqdm as original_tqdm
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "tqdm"])
    from tqdm import tqdm as original_tqdm

import datetime
import re

class CustomTqdm(original_tqdm):
    @classmethod
    def format_meter(cls, n, total, elapsed, ncols=None, prefix='', ascii=False, unit='it',
                     unit_scale=False, rate=None, bar_format=None, postfix=None, unit_divisor=1000,
                     initial=0, colour=None, **extra_kwargs):
        s = original_tqdm.format_meter(n, total, elapsed, ncols, prefix, ascii, unit, unit_scale, rate, bar_format, postfix, unit_divisor, initial, colour, **extra_kwargs)
        if "s/it" in s:
            match = re.search(r'(\d+(?:\.\d+)?)s/it', s)
            if match:
                val = float(match.group(1))
                if val > 0:
                    new_val = 1.0 / val
                    s = s.replace(match.group(0), "{:0.2f}it/s".format(new_val))
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        return f"[NVSHARE][INFO][{timestamp}] {s}"

tqdm = CustomTqdm

start_time = time.time()
n = 28000
device = torch.cuda.current_device()
x = torch.ones([n, n], dtype=torch.float32).to(device)
y = torch.ones([n, n], dtype=torch.float32).to(device)
for i in tqdm(range(4000)):
    z = torch.add(x, y)
torch.cuda.synchronize()  # Ensure computations are finished
print("PASS")
print("--- %s seconds ---" % (time.time() - start_time))
