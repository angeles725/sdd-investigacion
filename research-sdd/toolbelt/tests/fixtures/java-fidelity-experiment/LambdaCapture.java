public class LambdaCapture {
    public static java.util.function.IntSupplier make(int base) {
        return () -> base + 1;
    }
}
