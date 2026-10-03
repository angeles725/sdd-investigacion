package demo.pkg;

public final class BUnknown extends BObject
{
  public static final Property p = newProperty(Flags.READONLY | Flags.BOGUS_FLAG, BString.DEFAULT, null);
}
