using Godot;

// Issue #137: a very simple 2D scene where a square moves in a circle on screen.
// Runs for ~5s, then quits deterministically so the proof clip is bounded.
public partial class Issue137 : Node2D
{
    private ColorRect _square = null!;
    private double _t;

    private const float Radius = 150f;
    private const float AngularSpeed = 2.0f; // radians per second
    private const float HueSpeed = 0.2f; // full rainbow over the ~5s run
    private static readonly Vector2 Center = new Vector2(576, 324);

    public override void _Ready()
    {
        GD.Print("ISSUE137_DEMO_READY");

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
            Text = "Issue #137 demo — square moving in a circle",
            Position = new Vector2(48, 48),
        };
        layer.AddChild(label);

        _square = new ColorRect
        {
            Color = Color.FromHsv(0f, 0.85f, 0.95f),
            Size = new Vector2(40, 40),
            Position = CirclePosition(0.0),
        };
        layer.AddChild(_square);
    }

    public override void _Process(double delta)
    {
        _t += delta;
        _square.Position = CirclePosition(_t);
        float hue = Mathf.PosMod((float)_t * HueSpeed, 1.0f);
        _square.Color = Color.FromHsv(hue, 0.85f, 0.95f);
        if (_t >= 5.0)
            GetTree().Quit();
    }

    // Internal (not private) so gdUnit4 can assert the circular-motion math directly.
    internal static Vector2 CirclePosition(double t)
    {
        float angle = (float)t * AngularSpeed;
        var offset = new Vector2(Mathf.Cos(angle), Mathf.Sin(angle)) * Radius;
        return Center + offset - new Vector2(20, 20);
    }

    internal static Vector2 CircleCenter => Center;
    internal static float CircleRadius => Radius;
}
