extends Node2D

## Guinea-pig logic for the feasibility prototype.
## - `add()` is a pure, testable function: the GUT target (Phase 5) and the
##   target Claude mutates via MCP (Phase 4).
## - The SENTINEL print gives Phase 5 log-capture something unambiguous to grep.

const SENTINEL := "PROTO_SENTINEL_READY"

static func add(a: int, b: int) -> int:
	return a + b

func _ready() -> void:
	print(SENTINEL)
	print("add(2,3)=%d" % add(2, 3))
	# Self-quit so headless scene runs terminate deterministically (Phase 5/6).
	get_tree().create_timer(1.0).timeout.connect(func() -> void: get_tree().quit())
