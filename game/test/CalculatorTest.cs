namespace GodotAiIgloo.Tests;

using GdUnit4;
using static GdUnit4.Assertions;

[TestSuite]
public class CalculatorTest
{
    [TestCase]
    public void Add_returns_sum()
    {
        AssertInt(Calculator.Add(2, 3)).IsEqual(5);
    }
}
