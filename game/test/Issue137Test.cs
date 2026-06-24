namespace GodotAiIgloo.Tests;

using GdUnit4;
using static GdUnit4.Assertions;

[TestSuite]
public class Issue137Test
{
    [TestCase]
    public void CirclePosition_stays_at_constant_radius_from_center()
    {
        var halfSize = new Godot.Vector2(20, 20);

        for (double t = 0.0; t <= 4.0; t += 0.5)
        {
            var center = Issue137.CirclePosition(t) + halfSize;
            var distance = center.DistanceTo(Issue137.CircleCenter);
            AssertFloat(distance).IsEqualApprox(Issue137.CircleRadius, 0.01f);
        }
    }

    [TestCase]
    public void CirclePosition_moves_over_time()
    {
        var p0 = Issue137.CirclePosition(0.0);
        var p1 = Issue137.CirclePosition(1.0);

        AssertBool(p0.IsEqualApprox(p1)).IsFalse();
    }
}
