public class TryWithResources {
    public static String first(java.io.StringReader r) throws java.io.IOException {
        try (java.io.BufferedReader br = new java.io.BufferedReader(r)) {
            return br.readLine();
        }
    }
}
