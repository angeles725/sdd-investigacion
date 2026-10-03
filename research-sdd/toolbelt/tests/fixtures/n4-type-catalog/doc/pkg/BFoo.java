package demo.pkg;

public class BFoo extends BComponent
{
  /** string with comma, and paren ) inside */
  public static final Property in8 = newProperty(Flags.READONLY | Flags.SUMMARY, new BStatusNumeric(new BDouble(1.5, "a,b)"), BStatus.nullStatus), null);
  public static final Property out = newProperty(0, BBoolean.FALSE, BFacets.make("k", "v"));
  public static final Property label = newProperty(Flags.HIDDEN, new BString("open ( paren"), BFacets.NULL);
  public static final Action set = newAction(Flags.OPERATOR, BDouble.DEFAULT, null);
  public static final Action ping = newAction(Flags.ASYNC, BFacets.NULL);
  public static final Topic ev = newTopic(Flags.SUMMARY, null);
}
