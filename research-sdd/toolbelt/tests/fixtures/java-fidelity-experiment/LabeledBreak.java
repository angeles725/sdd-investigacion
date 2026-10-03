public class LabeledBreak {
    public static int find(int[][] grid, int needle) {
        int hits = 0;
        outer:
        for (int[] row : grid) {
            for (int v : row) {
                if (v == needle) {
                    hits++;
                    break outer;
                }
            }
        }
        return hits;
    }
}
