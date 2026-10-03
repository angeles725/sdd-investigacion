package demo.pkg;

public class BFoo
extends BComponent {
    public static final Property in8 = BFoo.newProperty((int)9, (BValue)new BStatusNumeric(new BDouble(1.5, "a,b)"), BStatus.nullStatus), null);
    public static final Property out = BFoo.newProperty((int)0, (BValue)BBoolean.FALSE, (BFacets)BFacets.make("k", "v"));
    public static final Property label = BFoo.newProperty((int)4, (BValue)new BString("open ( paren"), (BFacets)BFacets.NULL);
    public static final Action set = BFoo.newAction((int)256, (BValue)BDouble.DEFAULT, null);
    public static final Action ping = BFoo.newAction((int)16, BFacets.NULL);
    public static final Topic ev = BFoo.newTopic((int)8, null);
}
