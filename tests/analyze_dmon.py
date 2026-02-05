import sys

def parse_dmon(filename):
    data = []
    try:
        with open(filename, 'r') as f:
            lines = f.readlines()
    except FileNotFoundError:
        print("Error: dmon.log not found")
        return []

    for line in lines:
        if line.startswith('#') or 'sm' in line:
            continue
        parts = line.strip().split()
        if not parts: continue
        # Format: gpu pwr gtemp mtemp sm ...
        # index 4 is sm
        try:
            sm_util = int(parts[4])
            data.append(sm_util)
        except (ValueError, IndexError):
            pass
    return data

data = parse_dmon('/Users/luogangyi/Code/nvshare/tests/dmon.log')
print(f"Total samples collected: {len(data)}")

# Timeline assumptions (approximate):
# 0-10s: Startup/No Limit
# 10s: 30% Annotation applied
# 10-20s: Detection lag + transition
# 20-50s: 30% Limit Active (Step 1)
# 50s: 80% Annotation applied
# 50-60s: Detection lag + transition
# 60-90s: 80% Limit Active (Step 2)
# 90s+: Removal

def analyze(name, data, start_idx, end_idx, target):
    if start_idx >= len(data) or end_idx > len(data):
        print(f"[{name}] Not enough samples ({len(data)} < {end_idx})")
        return

    subset = data[start_idx:end_idx]
    if not subset:
        print(f"[{name}] No data in range {start_idx}-{end_idx}")
        return

    avg = sum(subset) / len(subset)
    print(f"[{name}] Target: {target}% | Actual Avg: {avg:.2f}% | Samples: {len(subset)}")
    
    # Deviation check (+/- 15%)
    diff = abs(avg - target)
    if diff > 15:
        print(f"  -> WARN: Deviation > 15%")
    else:
        print(f"  -> PASS: Within tolerance")

# Adjust indices based on script sleeps:
# Start logging -> Step 1 (immed) -> sleep 10 (detect) -> sleep 30 (sample)
# Actually:
# 0s: Pod run & dmon start
# ... (wait pod running) ...
# T0: Step 1 (30%) applied
# T0+10s: Detection wait
# T0+40s: End of 30% sampling
# T0+40s: Step 2 (80%) applied
# T0+50s: Detection wait
# T0+80s: End of 80% sampling

# Since dmon is started AFTER pod is running, index 0 is roughly T0.
# Let's use conservative windows:
analyze("Step 1 (30%)", data, 15, 35, 30)
analyze("Step 2 (80%)", data, 55, 75, 80)

