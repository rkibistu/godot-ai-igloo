using Godot;

// Demo Issue scene for Phase 1: draws visible content (a label + a sliding box),
// exercises the feature (Calculator), runs for ~5s, then quits DETERMINISTICALLY
// so the proof clip is bounded and the boot-smoke exits cleanly (rc 0).
public partial class Issue0 : Node2D
{
    private ColorRect _box = null!;
    private double _t;

    public override void _Ready()
    {
        GD.Print("ISSUE0_DEMO_READY");

        var layer = new CanvasLayer();
        AddChild(layer);

        var bg = new ColorRect
        {
            Color = new Color(0.10f, 0.11f, 0.15f),
            Size = new Vector2(1152, 648),
        };
        layer.AddChild(bg);

        var label = new Label
        {
            Text = $"Issue #0 demo — Calculator.Multiply(2, 3) = {Calculator.Multiply(2, 3)}",
            Position = new Vector2(48, 48),
        };
        layer.AddChild(label);

        _box = new ColorRect
        {
            Color = new Color(0.20f, 0.80f, 1.0f),
            Size = new Vector2(140, 140),
            Position = new Vector2(48, 160),
        };
        layer.AddChild(_box);
    }

    public override void _Process(double delta)
    {
        _t += delta;
        _box.Position = new Vector2(48f + (float)(_t * 180.0), 160f);
        if (_t >= 5.0)
            GetTree().Quit();
    }
}
