# yxml

The `yxml` [DUB package](https://code.dlang.org/packages/yxml) is a simple library that is designed to parse a subset of XML within the constraints of restricted D.

- Allows XML parsing in `nothrow @nogc`.
- One file, but depends on [`numem`](https://code.dlang.org/packages/numem) package for scoped DOM.


- The `yxml` parser from original is fast, however the DOM it constructs isn't particularly efficient. The original library was barebones and intended to be used as SAX parser. But this is a DOM-like API.

## Limitations

Not all of XML is supported. The limitations are stronger than the original [yxml](https://dev.yorhel.nl/yxml) library.

- Comments are ignored.
- XML Processing Instructions are ignored.
- Can't parse HTML.
- Can't _emit_ XML.
- Not validating, no namespace support.


## Usage


### 📈 Parsing a single value in a file
```d
// EXAMPLE: the file has this shape.
// ------------------------------------------------
// <?xml version="1.0" encoding="UTF-8"?>
// <results>
//    <metric value="5.8" />
// </results>
// ------------------------------------------------
// Note: This example assumes you can use the GC for error reporting,
// but `yxml` doesn't strictly require it.
void parseMyXMLData(const(char)[] xmlData) 
{
    import yxml;

    // Parse a whole XML file, builds a DOM.
    XmlDocument doc;
    doc.parse(xmlData);

    // Parsing error is dealt with error codes.
    if (doc.isError)
    {
        const(char)[] message = doc.errorMessage;
        // ...do something with the error, 
        // such as throwing if you can:
        throw new Exception(message.idup);
    }

    XmlElement root = doc.root;

    if (root.tagName != "results")
        throw new Exception("expected <results> as root XML anchor");

    foreach(e; root.getChildrenByTagName("metric"))
    {
        if (!e.hasAttribute("value"))
            throw new Exception(`expected attribute "value" in <metric>`);
        return to!double(e.getAttribute("value")); // return first seen
    }
    throw new Exception("expected <metric>");
}
```

### 📈 Iterate children of a `XmlElement`

- `childNodes` return range that iterates on children, who are all `XmlElement` themselves.
- `childElementCount` return the number of children.

```d
void parseCustomers(XmlElement parent)
{
    // Iterate on the child nodes of `parent`
    foreach(XmlElement node; parent.childNodes)
    {
        writeln(node.tagName);     // Display <tag> name.
        writeln(node.textContent); // Display its content and that of its children
    }
}
```

> 🧑‍💼 _**Pro XML parsing tip:** Use `.dup` or `.idup` to make copies of tag names of text content, because the lifetime of the DOM is the one of the `XmlDocument`. You don't want your characters string to disappear over you, right?_


### 📈 Find a child with given tag name

- Use `XmlElement.firstChildByTagName(const(char)[] tagName)` for first matching element.

```d
void parseCustomer(XmlElement customer)
{
    XmlElement name = customer.firstChildByTagName("name");
    if (name is null)
        throw new Exception("<customer> has no <name>!");
}
```

> 🧑‍💼 _**Pro XML parsing tip:** You can be even clearer in intent by using `.hasChildWithTagName`._



### 📈 Iterate children of a `XmlElement` by tag name

- `getChildrenByTagName` return range that iterates on direct children that match a given tag name, no recursion.

```d
void parseSupportDeskFile(XmlElement parent)
{
    foreach(XmlElement customer; parent.getChildrenByTagName("customer"))
    {
        // Do something with customer
    }
}
```

> 🧑‍💼 _**Pro XML parsing tip:** Use .array to get a slice rather than a range._
> ```d
> import std.array;
> XmlElement[] elems = node.getChildrenByTagName("customer").array;
> writeln("%s customers found.", elems.length);
> ```

### 📈 Get a single attribute

All these 3 examples are equivalent:
```d
void parseCustomers(XmlElement node)
{
    // null if such an attribute doesn't exist
    const(char)[] blurb = node.getAttribute("blurb");
    if (!blurb)
        throw new Exception(`no "blurb" attribute!`);
}
```

```d
void parseCustomers(XmlElement node)
{
    const(char)[] blurb = null;
    if (node.hasAttribute("blurb"))
    {
        XmlAttr attr = node.getAttributeNode("blurb");
        blurb = attr.value();
    }
    if (!blurb)
        throw new Exception(`no "blurb" attribute!`);
}
```

```d
void parseCustomers(XmlElement node)
{
    const(char)[] blurb = null;

    // Iterate on all attributes
    foreach(attr; node.attributes())
    {
        if (attr.name == "blurb")
            blurb = attr.value;
    }
    if (!blurb)
        throw new Exception(`no "blurb" attribute!`);
}
```
