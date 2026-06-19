extends GutTest

## GUT target for the Phase 5 done-gate. `add` is static, so no node instance
## is needed. Flip an assertion to confirm the gate correctly turns red.

const Main = preload("res://scripts/main.gd")

func test_add_basic() -> void:
	assert_eq(Main.add(2, 3), 5, "2 + 3 should equal 5")

func test_add_zero() -> void:
	assert_eq(Main.add(0, 0), 0, "0 + 0 should equal 0")
