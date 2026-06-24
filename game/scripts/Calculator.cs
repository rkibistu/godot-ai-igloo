// Pure logic — no Godot runtime needed, so gdUnit4 can test it fast (no [RequireGodotRuntime]).
public static class Calculator
{
    public static int Add(int a, int b) => a + b;

    public static int Multiply(int a, int b) => a * b;

    public static int Subtract(int a, int b) => a - b;

    public static int Divide(int a, int b) => a / b;
}
