module Chain;

struct Chain
{
    int usages;
    Chain[] links;
    string word;

    int opCmp ( ref const Chain chain ) const
    {
        return chain.usages - this.usages;
    }
}
