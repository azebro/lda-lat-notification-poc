# Delta Change Event Contract

`delta-change-envelope.v1.schema.json` is the canonical contract for events written to Event Hubs and consumed by the receiver.

The POC publishes only:

- `insert`
- `update_postimage`

The Kafka message key is `payload.signal_id`. The message value is the complete JSON envelope.

`payload.signal_id` is non-null and unique in the POC Delta table. The publisher and receiver must also enforce that `primary_key` equals `payload.signal_id`; this cross-field invariant is documented here because JSON Schema cannot express it portably.

The deterministic event ID is:

```text
vehicle_signals-{signal_id}-v{commit_version}-{change_type}
```

Examples in `examples/` must validate against the schema.

```powershell
./scripts/validate-contract.ps1
```