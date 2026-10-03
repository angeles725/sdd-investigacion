public class SynchronizedBlock {
    private final Object lock = new Object();
    private int n;

    public int bump() {
        synchronized (lock) {
            return ++n;
        }
    }
}
