# Result UX Roadmap

## Product Goal

Help a technician decide what happened, how urgent it is, and what to do next without reading raw ADB logs first.

## Recommended Result Flow

### 1. Decision Summary

Show one clear result state at the top: `Critical device fault detected`, `Application crash detected`, `No known critical signature`, or `Collection incomplete`.

Present severity counts, device serial, firmware/build identifier, collection time, and a short list of the three highest-priority actions. This is the first screen after collection completes.

### 2. Cause Groups

Show one expandable row per normalized root cause instead of every matching log line. Each row should contain severity, occurrence count, plain-language meaning, recommended action, and a confidence note.

Example: `Critical | Kernel panic | 1 occurrence | Firmware/vendor escalation required`.

### 3. Evidence And Traceability

Each group should expose the exact evidence line, source file, timestamp when available, and a button to open the source file at the matching line. Raw logs remain available but are secondary to the diagnosis.

### 4. Collection Quality

Separate expected access restrictions from true collection failures. A tombstone pull blocked by Android permissions should appear as `Not available on this device`, while a disconnected ADB session should appear as `Collection failed`.

### 5. Export And Handoff

Add `Copy incident summary`, `Open report folder`, and `Export support bundle` actions. The support bundle should exclude personal data by default or clearly mark what it includes.

## Delivery Sequence

- `0.1.x`: Stabilize collection, versioning, and report correctness.
- `0.2.0`: Replace the plain post-run result with the decision summary and grouped finding cards.
- `0.3.0`: Add evidence navigation, collection-quality states, and support-bundle export.

## Success Criteria

- A technician identifies the primary fault and next action in under 30 seconds.
- Repeated evidence does not visually inflate the number of independent incidents.
- Permission-limited sources are understandable without treating them as product failures.
