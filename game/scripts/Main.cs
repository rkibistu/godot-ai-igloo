using Godot;

public partial class Main : Node2D
{
    public override void _Ready()
    {
        // Sentinel for log-based smoke checks (mirrors the prototype's PROTO_SENTINEL_READY).
        GD.Print("PROTO_SENTINEL_READY");
        GD.Print($"2 + 3 = {Calculator.Add(2, 3)}");
    }
}
