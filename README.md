# yxml

The `yxml` [DUB package](https://code.dlang.org/packages/yxml) is a simple that is designed to parse a subset of XML withing the constraints of restricted D.

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
- Resulting DOM has only `Element` nodes, no `Text` nodes.


## Usage


### 📈 Parsing a file under `nothrow @nogc` constraint
```d
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
        // such as throwing if you can
    }
        
    XmlElement root = doc.root;    
    // ...access DOM here...
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
        writeln(node.tagName); // Display <tag> name.
        writeln(node.content); // Display its .textContent
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

```d
void parseCustomers(XmlElement node)
{
    // null if such an attribute doesn't exist
    const(char)[] blurb = node.getAttribute("blurb");
    if (blurb is null)
        throw new Exception(`no "blurb" attribute!`);  
}
```
```d
// TODO iterate on attribute nodes
// TODO atribute name() and value()
```