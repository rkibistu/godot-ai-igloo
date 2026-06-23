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

    [TestCase]
    public void Multiply_returns_product()
    {
        AssertInt(Calculator.Multiply(2, 3)).IsEqual(6);
    }

    [TestCase]
    public void Subtract_returns_difference()
    {
        AssertInt(Calculator.Subtract(5, 3)).IsEqual(2);
    }

    [TestCase]
    public void Subtract_returns_negative_difference()
    {
        AssertInt(Calculator.Subtract(0, 4)).IsEqual(-4);
    }
}
