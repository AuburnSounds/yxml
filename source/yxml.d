/* Copyright (c) 2013-2014 Yoran Heling
   Copyright (c) 2023      Guillaume Piolat

  Permission is hereby granted, free of charge, to any person obtaining
  a copy of this software and associated documentation files (the
  "Software"), to deal in the Software without restriction, including
  without limitation the rights to use, copy, modify, merge, publish,
  distribute, sublicense, and/or sell copies of the Software, and to
  permit persons to whom the Software is furnished to do so, subject to
  the following conditions:

  The above copyright notice and this permission notice shall be included
  in all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
  CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
  TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
  SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
module yxml;

import dplug.core.nogc;
import dplug.core.vec;
import core.stdc.stdlib: malloc, free;
import core.stdc.string: memset, strlen;

nothrow @nogc:

public
{
    /// XML parser object.
    /// This is only a DOM-lite, do not expect any type of conformance.
    /// In particular, there is only one type of Node in this tree: the XmlElement.
    /// This is also a sort of 'context' for the DOM tree.
    struct XmlDocument
    {
    nothrow @nogc:

        alias _root this;

        /// Clears DOM-lite, parse XML source.
        /// Returns: `true` on success.
        bool parse(const(char)[] source)
        {
            clearError();

            // Lazily allocate memory for parsing.
            allocateParser();

            // Parse it all, builds a read-only DOM.
            yxml_t* parser = _mergedAlloc;
            void* stackBuffer = _mergedAlloc + 1;
            yxml_init(parser, stackBuffer, BUFSIZE);
            yxml_t *x; /* An initialized state */

            // yxml seems to be made to be SAX. We just parse whole file to build a small 
            // DOM and ruin all the efficiency.

            // weak pointer to currently create element.
            // It has been added to its parent already.
            XmlElement current = null;
            XmlText currentText = null;
            XmlAttr currentAttr = null;

            for (size_t n = 0; n < source.length; ++n)
            {
                yxml_ret_t r = yxml_parse(parser, source[n]);
                if (r < 0)
                {
                    setError(yxml_error_string(r));
                    return false;
                }
                else
                {
                    switch(r)
                    {
                        case YXML_OK: 
                            // No new token
                            break;

                        case YXML_ELEMSTART:
                            if (current is null)
                            {
                                _root = mallocNew!XmlElement(null, parser.elem);
                                current = _root;
                            }
                            else
                            {
                                currentText = null;
                                // Append a child to current Element, which becomes the new current
                                XmlElement parent = current;
                                assert(parent !is null);
                                XmlElement here = mallocNew!XmlElement(parent, parser.elem);
                                parent._children ~= here;
                                current = here;
                            }
                            break;
                            
                        case YXML_CONTENT:
                            if (currentText is null)
                            {
                                // Append text node to current Element, point to it
                                XmlElement parent = current;
                                XmlText here = mallocNew!XmlText(parent);
                                parent._children ~= here;
                                currentText = here;
                            }
                            currentText._data.appendCString(parser.data.ptr);
                            break;

                        case YXML_ELEMEND:
                            current = current.parentElement();
                            currentText = null;
                            break;

                        case YXML_ATTRSTART:
                            current._attributes ~= mallocNew!XmlAttr(parser.attr, current);
                            currentAttr = current._attributes[$-1];
                            break;

                        case YXML_ATTRVAL:
                            currentAttr._value.appendCString(parser.data.ptr);
                            break;

                        case YXML_ATTREND:
                            break;

                        case YXML_PISTART:
                            break;

                        case YXML_PICONTENT:
                            break;

                        case YXML_PIEND:
                            break;

                        default:
                            assert(false);
                    }
                }
            }

            // Must end correctly
            if (yxml_eof(parser) != YXML_OK)
            {
                setError("XML end of file is incorrect");
                return false;
            }

            return true;
        }

        /// Has something been successfully parsed?
        bool isError()
        {
            return _errorStr !is null;
        }

        /// Return: error message in case of error, or null.
        const(char)[] errorMessage()
        {
            return _errorStr;
        }

        /// Gets the root of the document tree.
        XmlElement root()
        {
            return _root;
        }

        ~this()
        {
            setError("uninitialized");
            free(_mergedAlloc);
            destroyFree(_root);
        }

    private:

        XmlElement _root;

        const(char)[] _errorStr = "uninitialized";

        void clearError()
        {
            _errorStr = null;
        }

        void setError(const(char)[] message)
        {
            _errorStr = message;
            destroyFree(_root);
            _root = null;
        }

        // Recommended by yxml's documentation, one single allocation.
        // Nesting limit depends on this value.
        enum BUFSIZE = 4 * 1024; 

        yxml_t* _mergedAlloc = null;

        void allocateParser()
        {
            if (_mergedAlloc !is null)
                return; // already allocated. Reusing XmlDocument is thus a bit faster.
            enum size_t allocSize = yxml_t.sizeof + BUFSIZE;
            _mergedAlloc = cast(yxml_t*) malloc(allocSize);
        }
    }

    enum XmlNodeType
    {
        element,
        text
    }

    /// Base class of DOM node.
    class XmlNode
    {
    public:
    nothrow:
    @nogc:

        this(XmlNodeType type, XmlNode parent)
        {
            _type = type;
            _parent = parent;
        }

        ~this()
        {
            foreach_reverse(c; _children)
            {
                destroyFree(c);
            }
        }

        /// Number of children.
        final size_t childElementCount()
        {
            return _children.length;
        }

        /// `childNodes` returns a foreach-able range of child nodes of the given Element where 
        /// the first child node is assigned index 0.
        final auto childNodes()
        {
            return ChildRange(this, 0, childElementCount());
        }

        /// Returns: parent, if any. If none, this is the document root, which is not represented.
        final XmlNode parentNode()
        {
            return _parent;
        }

        /// Returns: parent, if it's an Element.
        final XmlElement parentElement()
        {
            if ((_parent !is null) && (_parent._type == XmlNodeType.element))
                return unsafeObjectCast!XmlElement(_parent);
            else
                return null;
        }

        /// `firstChild` returns a borrowed reference to the first child in the node.
        /// Returns: First child, or `null` if no child.
        final XmlNode firstChild()
        {
            if (_children.length == 0)
                return null;
            return _children[0];
        }

        /// `lastChild` returns a borrowed reference to the last child of the node.
        /// Returns: Last child, or `null` if no child.
        final XmlNode lastChild()
        {
            if (_children.length == 0)
                return null;
            return _children[$-1];
        }

        /// Return next sibling in parent's children, or null if last child.
        final XmlNode nextSibling()
        {
            if (_parent is null)
                return null;
            auto iter = _parent.childNodes;
            size_t numChildren = iter.length;
            size_t n = 0;
            foreach(XmlNode node; iter)
            {
                if (node is this)
                {
                    if (n + 1 == numChildren)
                        return null;
                    return iter[n+1];
                }
                ++n;
            }
            assert(false);
        }

        /// "The textContent property of the Node interface represents the text content of the node
        /// and its descendants.
        final const(char)[] textContent()
        {
            _content.clearContents();
            appendTextContent(_content);
            return _content[];
        }

    protected:
        abstract void appendTextContent(ref Vec!char outbuf);
        abstract void appendInnerHTML(ref Vec!char outbuf);

        // Allows to define range-types more easily.
        mixin template NodeRangeTemplate(OutNodeType, bool Recursive = false)
        {
        public:
        nothrow:
        @nogc:
            XmlNode root;

            // Current position
            XmlNode elem;
            size_t start, stop;

            bool empty()
            { 
                return !progressUntilMatch();
            }

            // Note: match() MUST ensure the selected node has right type.
            OutNodeType front() 
            { 
                return unsafeObjectCast!OutNodeType(elem._children[start]); 
            }

            void popFront()
            { 
                start += 1;
                progressUntilMatch();
            }

            // return true on match
            private bool progressUntilMatch()
            {
                while(start < stop)
                {
                    if (match(elem._children[start]))
                        return true;

                    start += 1;
                }
                // TODO: recursive
                return false; // no match found
            }
        }

    private:

        // Node type
        XmlNodeType _type;

        // Link to parent, root has _parent == null.
        XmlNode _parent = null;

        // Owned children.
        Vec!XmlNode _children;

        // Cached content string. Computed on request.
        Vec!char _content;

        static struct ChildRange
        {
            nothrow @nogc:

            XmlNode elem;
            size_t start, stop;
            bool empty()       { return stop <= start; }
            void popFront()    { start++; }
            void popBack()     { stop--; }
            size_t length()    { return stop - start; }
            XmlNode front()    { return elem._children[start]; }
            XmlNode opIndex(size_t index) { return elem._children[start + index]; }
        }

        static struct ElementRange
        {
        nothrow @nogc:
            XmlElement elem;
            size_t start, stop; // start == -1 means "need to find first XmlElement"
            bool empty()       { init(); return stop <= start; }
            void popFront()    { start++; skipNonElement(); }
            size_t length()    { return stop - start; }
            XmlElement front() { XmlElement r = cast(XmlElement)elem._children[start]; assert(r); return r; }

        private:
            void init()
            {
                if (start == -1)
                {
                    start = 0;
                    skipNonElement();
                }
            }
            void skipNonElement()
            {
                while(start < stop)
                {
                    if (cast(XmlElement)(elem._children[start]) !is null)
                        break;
                    start++;
                }
            }
        }
    }

    /// CharacterData interface represents a Node object that contains characters.
    class XmlCharacterData : XmlNode
    {
    public:
    nothrow:
    @nogc:
        this(XmlNodeType type, XmlNode parent)
        {
            super(type, parent);
        }

        const(char)[] data()
        {
            return _data[];
        }

        size_t length()
        {
            return _data.length();
        }

    protected:

        override void appendTextContent(ref Vec!char outbuf)
        {
            outbuf.pushBack(_data);
        }

        override void appendInnerHTML(ref Vec!char outbuf)
        {
            outbuf.pushBack(_data);
        }

    private:
        Vec!char _data;

    }

    final class XmlText : XmlCharacterData
    {
    public:
    nothrow:
    @nogc:
        this(XmlNode parent)
        {
            super(XmlNodeType.text, parent);
        }
    }

    final class XmlElement : XmlNode
    {
    public:
    nothrow:
    @nogc:

        // Constructs an Element-like object, with a tag name,
        // an optional parent (weak pointer), and owned children 
        // null = no parent
        this(XmlNode parent, const(char)* elemNameZ)
        {
            super(XmlNodeType.element, parent);
            _tagName.appendCString(elemNameZ);
        }

        /// Returns: tag name.
        const(char)[] tagName()
        {
            return _tagName[];
        }

        /// `children` returns a foreach-able range of XmlElement nodes of the given XmlElement.
        /// To get all child nodes, including non-element nodes like text, use XmlNode.childNodes.
        final auto children()
        {
            return ElementRange(this, -1, childElementCount());
        }

        /// Gets the XML markup contained within the element.
        const(char)[] innerHTML()
        {
            _innerHTMLStr.clearContents();
            appendInnerHTML(_innerHTMLStr);
            return _innerHTMLStr[];
        }

        ///TODO firstElementChild


        ///TODO lastElementChild
        ///TODO nextElementSibling

        // <ATTRIBUTES>

        /// `attributes` returns a foreach-able range of attributes.
        auto attributes()
        {
            return AttributeRange(this, 0, _attributes.length);
        }

        /// Returns a boolean value indicating whether the element has any attributes or not.
        bool hasAttributes()
        {
            return _attributes.length != 0;
        }

        /// Returns a boolean value indicating whether the element has a particular attribute.
        bool hasAttribute(const(char)[] attrName)
        {
            return getAttributeNode(attrName) !is null;
        }

        /// Returns borrowed reference to an attribute, as an XmlAttr node.
        /// Or `null` if doesn't exist.
        XmlAttr getAttributeNode(const(char)[] attrName)
        {
            foreach(XmlAttr attr; attributes())
            {
                if (attr.name == attrName)
                    return attr;
            }
            return null;
        }

        /// Returns the value of a specified attribute on the element.
        const(char)[] getAttribute(const(char)[] attrName)
        {
            XmlAttr attr = getAttributeNode(attrName);
            if (attr is null)
                return null;
            return attr.value;
        }

        // </ATTRIBUTES>

        /// Iterate children by tag name.
        auto getChildrenByTagName(const(char)[] name)
        {
            return TagNameChildRange!false(this, this, 0, childElementCount(), name);
        }

        /// Iterate children recursively by tag name.
        /*auto getElementsByTagName(const(char)[] name)
        {
            // same but recursive
            return TagNameChildRange!true(this, this, 0, childElementCount(), name);
        }*/

        /// Firt child with a given tag name, or `null` if doesn't exist.
        XmlElement firstChildByTagName(const(char)[] name)
        {
            auto r = getChildrenByTagName(name);
            if (r.empty)
                return null;
            else
                return r.front();
        }

        /// Returns: `true` if at least one child with given tag name exists.
        bool hasChildWithTagName(const(char)[] name)
        {
            return firstChildByTagName(name) !is null;
        }

    protected:
        override void appendTextContent(ref Vec!char outbuf)
        {
            for (int n = 0; n < _children.length; ++n)
            {
                _children[n].appendTextContent(outbuf);
            }
        }

        override void appendInnerHTML(ref Vec!char outbuf)
        {
            // FUTURE: probably some escaping to do in case of non-XML strings

            for (int n = 0; n < _children.length; ++n)
            {
                XmlNode node = _children[n];                
                if (node._type == XmlNodeType.element)
                {
                    XmlElement e = unsafeObjectCast!XmlElement(node);
                    outbuf.pushBack('<');
                    outbuf.pushBack(e._tagName); // must be valid, else XML wouldn't have parsed

                    foreach(XmlAttr attr; e.attributes())
                    {
                        outbuf.pushBack(' ');
                        outbuf.pushBack(attr._name); // same remark
                        outbuf.pushBack('=');
                        outbuf.pushBack('\"');
                        outbuf.pushBack(attr._value); // same remark
                        outbuf.pushBack('\"');
                    }
                    outbuf.pushBack('>');
                    e.appendInnerHTML(outbuf);
                    outbuf.pushBack('<');
                    outbuf.pushBack('/');
                    outbuf.pushBack(e._tagName);
                    outbuf.pushBack('>');
                }
                else
                {
                    node.appendInnerHTML(outbuf);
                }
            }
        }

    private:
        // Tag name eg: <html> => "html"
        Vec!char _tagName;
        
        // Owned attributes.
        Vec!XmlAttr _attributes;

        // Cached value for .innerHTML
        Vec!char _innerHTMLStr;

        static struct AttributeRange
        {
        nothrow @nogc:
            XmlElement elem;
            size_t start, stop;
            bool empty()       { return stop <= start; }
            void popFront()    { start++; }
            void popBack()     { stop--; }
            size_t length()    { return stop - start; }
            XmlAttr front()    { return elem._attributes[start]; }
            XmlAttr opIndex(size_t index) { return elem._attributes[start + index]; }
        }

        static struct TagNameChildRange(bool Recursive)
        {
        nothrow @nogc:
            mixin NodeRangeTemplate!(XmlElement, Recursive);
            const(char)[] nameSearched;

            private bool match(XmlNode candidate)
            {
                if (candidate._type != XmlNodeType.element)
                    return false;
                XmlElement elem = unsafeObjectCast!XmlElement(candidate);
                return elem !is null && elem.tagName() == nameSearched;
            }
        }
    }

    final class XmlAttr
    {
    public:
    nothrow @nogc:

        this(const(char)* attrNameZ, XmlElement owner)
        {
            _owner = owner;
            _name.appendCString(attrNameZ);
        }

        /// Returns: the owning Element of the attribute.
        XmlElement ownerElement()
        {
            return _owner;
        }

        /// Returns: attribute's name.
        const(char)[] name()
        {
            return _name[];
        }
        ///ditto
        alias localName = name;

        /// Returns: attribute's value.
        const(char)[] value()
        {
            return _value[];
        }

    private:
        XmlElement _owner; // borrow ref to owning Element
        Vec!char _name;
        Vec!char _value;
    }
}

private:

void appendCString(ref Vec!char str, const(char)* source)
{
    // const_cast here
    str.pushBack(cast(char[]) source[0..strlen(source)]);
}

T unsafeObjectCast(T)(Object obj)
{
    return cast(T)(cast(void*)(obj));
}


//
// <PARSER STARTS HERE>
//


/* Full API documentation for this library can be found in the "yxml.md" file
 * in the yxml git repository, or online at http://dev.yorhel.nl/yxml/man */

alias yxml_ret_t = int;

enum : yxml_ret_t 
{
    YXML_EEOF        = -5, /* Unexpected EOF                             */
    YXML_EREF        = -4, /* Invalid character or entity reference (&whatever;) */
    YXML_ECLOSE      = -3, /* Close tag does not match open tag (<Tag> .. </OtherTag>) */
    YXML_ESTACK      = -2, /* Stack overflow (too deeply nested tags or too long element/attribute name) */
    YXML_ESYN        = -1, /* Syntax error (unexpected byte)             */
    YXML_OK          =  0, /* Character consumed, no new token present   */
    YXML_ELEMSTART   =  1, /* Start of an element:   '<Tag ..'           */
    YXML_CONTENT     =  2, /* Element content                            */
    YXML_ELEMEND     =  3, /* End of an element:     '.. />' or '</Tag>' */
    YXML_ATTRSTART   =  4, /* Attribute:             'Name=..'           */
    YXML_ATTRVAL     =  5, /* Attribute value                            */
    YXML_ATTREND     =  6, /* End of attribute       '.."'               */
    YXML_PISTART     =  7, /* Start of a processing instruction          */
    YXML_PICONTENT   =  8, /* Content of a PI                            */
    YXML_PIEND       =  9  /* End of a processing instruction            */
}

string yxml_error_string(yxml_ret_t r)
{
    assert(r < 0);
    switch(r)
    {
        case YXML_EEOF     : return "Unexpected EOF";
        case YXML_EREF     : return "Invalid character or entity reference (&whatever;)";
        case YXML_ECLOSE   : return "Close tag does not match open tag (<Tag> .. </OtherTag>)";
        case YXML_ESTACK   : return "Stack overflow (too deeply nested tags or too long element/attribute name)";
        case YXML_ESYN     : return "Syntax error (unexpected byte)";
        default:
            assert(false);
    }
}

/* When, exactly, are tokens returned?
 *
 * <TagName
 *   '>' ELEMSTART
 *   '/' ELEMSTART, '>' ELEMEND
 *   ' ' ELEMSTART
 *     '>'
 *     '/', '>' ELEMEND
 *     Attr
 *       '=' ATTRSTART
 *         "X ATTRVAL
 *           'Y'  ATTRVAL
 *             'Z'  ATTRVAL
 *               '"' ATTREND
 *                 '>'
 *                 '/', '>' ELEMEND
 *
 * </TagName
 *   '>' ELEMEND
 */
struct yxml_t
{
    /* PUBLIC (read-only) */

    /* Name of the current element, zero-length if not in any element. Changed
     * after YXML_ELEMSTART. The pointer will remain valid up to and including
     * the next non-YXML_ATTR* token, the pointed-to buffer will remain valid
     * up to and including the YXML_ELEMEND for the corresponding element. */
    char *elem;

    /* The last read character(s) of an attribute value (YXML_ATTRVAL), element
     * data (YXML_CONTENT), or processing instruction (YXML_PICONTENT). Changed
     * after one of the respective YXML_ values is returned, and only valid
     * until the next yxml_parse() call. Usually, this string only consists of
     * a single byte, but multiple bytes are returned in the following cases:
     * - "<?SomePI ?x ?>": The two characters "?x"
     * - "<![CDATA[ ]x ]]>": The two characters "]x"
     * - "<![CDATA[ ]]x ]]>": The three characters "]]x"
     * - "&#N;" and "&#xN;", where dec(n) > 127. The referenced Unicode
     *   character is then encoded in multiple UTF-8 bytes.
     */
    char[8] data;

    /* Name of the current attribute. Changed after YXML_ATTRSTART, valid up to
     * and including the next YXML_ATTREND. */
    char *attr;

    /* Name/target of the current processing instruction, zero-length if not in
     * a PI. Changed after YXML_PISTART, valid up to (but excluding)
     * the next YXML_PIEND. */
    char *pi;

    /* Line number, byte offset within that line, and total bytes read. These
     * values refer to the position _after_ the last byte given to
     * yxml_parse(). These are useful for debugging and error reporting. */
    ulong byte_;
    ulong total;
    uint line;


    /* PRIVATE */
    int state;
    char *stack; /* Stack of element names + attribute/PI name, separated by \0. Also starts with a \0. */
    size_t stacksize, stacklen;
    uint reflen;
    uint quote;
    int nextstate; /* Used for '@' state remembering and for the "string" consuming state */
    uint ignore;
    const(char)*string_;
}



/* Returns the length of the element name (x.elem), attribute name (x.attr),
 * or PI name (x.pi). This function should ONLY be used directly after the
 * YXML_ELEMSTART, YXML_ATTRSTART or YXML_PISTART (respectively) tokens have
 * been returned by yxml_parse(), calling this at any other time may not give
 * the correct results. This function should also NOT be used on strings other
 * than x.elem, x.attr or x.pi. */
size_t yxml_symlen(yxml_t *x, const(char) *s)
{
    return (x.stack + x.stacklen) - cast(const(char)*)s;
}

alias yxml_state_t = int;
enum : yxml_state_t
{
    YXMLS_string,
    YXMLS_attr0,
    YXMLS_attr1,
    YXMLS_attr2,
    YXMLS_attr3,
    YXMLS_attr4,
    YXMLS_cd0,
    YXMLS_cd1,
    YXMLS_cd2,
    YXMLS_comment0,
    YXMLS_comment1,
    YXMLS_comment2,
    YXMLS_comment3,
    YXMLS_comment4,
    YXMLS_dt0,
    YXMLS_dt1,
    YXMLS_dt2,
    YXMLS_dt3,
    YXMLS_dt4,
    YXMLS_elem0,
    YXMLS_elem1,
    YXMLS_elem2,
    YXMLS_elem3,
    YXMLS_enc0,
    YXMLS_enc1,
    YXMLS_enc2,
    YXMLS_enc3,
    YXMLS_etag0,
    YXMLS_etag1,
    YXMLS_etag2,
    YXMLS_init,
    YXMLS_le0,
    YXMLS_le1,
    YXMLS_le2,
    YXMLS_le3,
    YXMLS_lee1,
    YXMLS_lee2,
    YXMLS_leq0,
    YXMLS_misc0,
    YXMLS_misc1,
    YXMLS_misc2,
    YXMLS_misc2a,
    YXMLS_misc3,
    YXMLS_pi0,
    YXMLS_pi1,
    YXMLS_pi2,
    YXMLS_pi3,
    YXMLS_pi4,
    YXMLS_std0,
    YXMLS_std1,
    YXMLS_std2,
    YXMLS_std3,
    YXMLS_ver0,
    YXMLS_ver1,
    YXMLS_ver2,
    YXMLS_ver3,
    YXMLS_xmldecl0,
    YXMLS_xmldecl1,
    YXMLS_xmldecl2,
    YXMLS_xmldecl3,
    YXMLS_xmldecl4,
    YXMLS_xmldecl5,
    YXMLS_xmldecl6,
    YXMLS_xmldecl7,
    YXMLS_xmldecl8,
    YXMLS_xmldecl9
}

bool yxml_isChar(char c)
{
    return true;
}

/* 0xd should be part of SP, too, but yxml_parse() already normalizes that into 0xa */
bool yxml_isSP(char c)
{
    return c == 0x20 || c == 0x09 || c == 0x0a;
}

bool yxml_isAlpha(char c)
{
    uint diff = (c | 32) - 'a';
    return diff < 26;
}

bool yxml_isNum(char c)
{
    uint diff = (c - '0');
    return diff >= 0 && diff < 10;
}

bool yxml_isHex(char c)
{
    uint diff = (c | 32) - 'a';
    return yxml_isNum(c) || (diff < 6);
}

bool yxml_isEncName(char c)
{
    return yxml_isAlpha(c) || yxml_isNum(c) || c == '.' || c == '_' || c == '-';
}

bool yxml_isNameStart(char c)
{
    return yxml_isAlpha(c) || c == ':' || c == '_' || c >= 128;
}

bool yxml_isName(char c)
{
    return yxml_isNameStart(c) || yxml_isNum(c) || c == '-' || c == '.';
} 

/* XXX: The valid characters are dependent on the quote char, hence the access to x.quote */

bool yxml_isAttValue(yxml_t *x, char c)
{
    return yxml_isChar(c) && c != x.quote && c != '<' && c != '&';
}



/* Anything between '&' and ';', the yxml_ref* functions will do further
 * validation. Strictly speaking, this is "yxml_isName(c) || c == '#'", but
 * this parser doesn't understand entities with '.', ':', etc, anwyay.  */
bool yxml_isRef(char c)
{
    return (yxml_isNum(c) || yxml_isAlpha(c) || c == '#');
}

ulong INTFROM5CHARS(char a, char b, char c, char d, char e)
{
    return
    (((cast(ulong)(a))<<32) 
     | ((cast(ulong)(b))<<24) 
     | ((cast(ulong)(c))<<16) 
     | ((cast(ulong)(d))<<8) 
     | cast(ulong)(e));
}

/* Set the given char value to ch (0<=ch<=255). */
void yxml_setchar(char *dest, char ch) 
{
    *dest = ch;
}

/* Similar to yxml_setchar(), but will convert ch (any valid unicode point) to
 * UTF-8 and appends a '\0'. dest must have room for at least 5 bytes. */
void yxml_setutf8(char *dest, uint ch) 
@system /* memory-safe if dest[0..5] writeable. */
{
    if(ch <= 0x007F)
        yxml_setchar(dest++, cast(char)ch);
    else if(ch <= 0x07FF) {
        yxml_setchar(dest++, cast(char)(0xC0 | (ch>>6)));
        yxml_setchar(dest++, cast(char)(0x80 | (ch & 0x3F)));
    } else if(ch <= 0xFFFF) {
        yxml_setchar(dest++, cast(char)(0xE0 | (ch>>12)));
        yxml_setchar(dest++, cast(char)(0x80 | ((ch>>6) & 0x3F)));
        yxml_setchar(dest++, cast(char)(0x80 | (ch & 0x3F)));
    } else {
        yxml_setchar(dest++, cast(char)(0xF0 | (ch>>18)));
        yxml_setchar(dest++, cast(char)(0x80 | ((ch>>12) & 0x3F)));
        yxml_setchar(dest++, cast(char)(0x80 | ((ch>>6) & 0x3F)));
        yxml_setchar(dest++, cast(char)(0x80 | (ch & 0x3F)));
    }
    *dest = 0;
}
yxml_ret_t yxml_datacontent(yxml_t *x, uint ch)
{
    yxml_setchar(x.data.ptr, cast(ubyte)ch);
    x.data[1] = 0;
    return YXML_CONTENT;
}

yxml_ret_t yxml_datapi1(yxml_t *x, uint ch)
{
    yxml_setchar(x.data.ptr, cast(ubyte)ch);
    x.data[1] = 0;
    return YXML_PICONTENT;
}

yxml_ret_t yxml_datapi2(yxml_t *x, uint ch)
{
    x.data[0] = '?';
    yxml_setchar(x.data.ptr+1, cast(char)ch);
    x.data[2] = 0;
    return YXML_PICONTENT;
}


yxml_ret_t yxml_datacd1(yxml_t *x, uint ch)
{
    x.data[0] = ']';
    yxml_setchar(x.data.ptr + 1, cast(char)ch);
    x.data[2] = 0;
    return YXML_CONTENT;
}

yxml_ret_t yxml_datacd2(yxml_t *x, uint ch)
{
    x.data[0] = ']';
    x.data[1] = ']';
    yxml_setchar(x.data.ptr + 2, cast(char)ch);
    x.data[3] = 0;
    return YXML_CONTENT;
}

yxml_ret_t yxml_dataattr(yxml_t *x, uint ch)
{
    /* Normalize attribute values according to the XML spec section 3.3.3. */
    yxml_setchar(x.data.ptr, ch == 0x9 || ch == 0xa ? 0x20 : cast(char)ch);
    x.data[1] = 0;
    return YXML_ATTRVAL;
}

yxml_ret_t yxml_pushstack(yxml_t *x, char **res, uint ch)
{
    if(x.stacklen+2 >= x.stacksize)
        return YXML_ESTACK;
    x.stacklen++;
    *res = cast(char *)x.stack + x.stacklen;
    x.stack[x.stacklen] = cast(char)ch;
    x.stacklen++;
    x.stack[x.stacklen] = 0;
    return YXML_OK;
}

yxml_ret_t yxml_pushstackc(yxml_t *x, uint ch)
{
    if(x.stacklen+1 >= x.stacksize)
        return YXML_ESTACK;
    x.stack[x.stacklen] = cast(char)ch;
    x.stacklen++;
    x.stack[x.stacklen] = 0;
    return YXML_OK;
}

void yxml_popstack(yxml_t *x)
{
    do
        x.stacklen--;
    while(x.stack[x.stacklen]);
}

yxml_ret_t yxml_elemstart  (yxml_t *x, uint ch)
{ 
    return yxml_pushstack(x, &x.elem, ch); 
}

yxml_ret_t yxml_elemname   (yxml_t *x, uint ch)
{ 
    return yxml_pushstackc(x, ch); 
}

yxml_ret_t yxml_elemnameend(yxml_t *x, uint ch) 
{ 
    return YXML_ELEMSTART;
}

/* Also used in yxml_elemcloseend(), since this function just removes the last
 * element from the stack and returns ELEMEND. */
yxml_ret_t yxml_selfclose(yxml_t *x, uint ch)
{
    yxml_popstack(x);
    if(x.stacklen) {
        x.elem = cast(char *)x.stack+x.stacklen-1;
        while(*(x.elem-1))
            x.elem--;
        return YXML_ELEMEND;
    }
    x.elem = cast(char *)x.stack;
    x.state = YXMLS_misc3;
    return YXML_ELEMEND;
}


yxml_ret_t yxml_elemclose(yxml_t *x, uint ch)
{
    if(*(cast(char *)x.elem) != ch)
        return YXML_ECLOSE;
    x.elem++;
    return YXML_OK;
}


yxml_ret_t yxml_elemcloseend(yxml_t *x, uint ch)
{
    if(*x.elem)
        return YXML_ECLOSE;
    return yxml_selfclose(x, ch);
}


yxml_ret_t yxml_attrstart  (yxml_t *x, uint ch) { return yxml_pushstack(x, &x.attr, ch); }
yxml_ret_t yxml_attrname   (yxml_t *x, uint ch) { return yxml_pushstackc(x, ch); }
yxml_ret_t yxml_attrnameend(yxml_t *x, uint ch) { return YXML_ATTRSTART; }
yxml_ret_t yxml_attrvalend (yxml_t *x, uint ch) { yxml_popstack(x); return YXML_ATTREND; }


yxml_ret_t yxml_pistart  (yxml_t *x, uint ch) { return yxml_pushstack(x, &x.pi, ch); }
yxml_ret_t yxml_piname   (yxml_t *x, uint ch) { return yxml_pushstackc(x, ch); }
yxml_ret_t yxml_piabort  (yxml_t *x, uint ch) { yxml_popstack(x); return YXML_OK; }
yxml_ret_t yxml_pinameend(yxml_t *x, uint ch) {
    return (x.pi[0]|32) == 'x' && (x.pi[1]|32) == 'm' && (x.pi[2]|32) == 'l' && !x.pi[3] ? YXML_ESYN : YXML_PISTART;
}
yxml_ret_t yxml_pivalend (yxml_t *x, uint ch) { yxml_popstack(x); x.pi = cast(char *)x.stack; return YXML_PIEND; }


yxml_ret_t yxml_refstart(yxml_t *x, uint ch) 
{
    memset(x.data.ptr, 0, (x.data).sizeof);
    x.reflen = 0;
    return YXML_OK;
}

yxml_ret_t yxml_ref(yxml_t *x, uint ch) 
{
    if(x.reflen >= (x.data).sizeof - 1)
        return YXML_EREF;
    yxml_setchar(x.data.ptr + x.reflen, cast(char)ch);
    x.reflen++;
    return YXML_OK;
}


yxml_ret_t yxml_refend(yxml_t *x, yxml_ret_t ret) 
{
    char *r = cast(char *)x.data;
    uint ch = 0;
    if(*r == '#') {
        if(r[1] == 'x')
            for(r += 2; yxml_isHex(*r); r++)
                ch = (ch<<4) + (*r <= '9' ? *r-'0' : (*r|32)-'a' + 10);
        else
            for(r++; yxml_isNum(*r); r++)
                ch = (ch*10) + (*r-'0');
        if(*r)
            ch = 0;
    } else {
        ulong i = INTFROM5CHARS(r[0], r[1], r[2], r[3], r[4]);
        ch =
            i == INTFROM5CHARS('l','t', 0,  0, 0) ? '<' :
            i == INTFROM5CHARS('g','t', 0,  0, 0) ? '>' :
            i == INTFROM5CHARS('a','m','p', 0, 0) ? '&' :
            i == INTFROM5CHARS('a','p','o','s',0) ? '\'':
            i == INTFROM5CHARS('q','u','o','t',0) ? '"' : 0;
    }

    /* Codepoints not allowed in the XML 1.1 definition of a Char */
    if(!ch || ch > 0x10FFFF || ch == 0xFFFE || ch == 0xFFFF || (ch-0xDFFF) < 0x7FF)
        return YXML_EREF;
    yxml_setutf8(x.data.ptr, ch);
    return ret;
}


yxml_ret_t yxml_refcontent(yxml_t *x, uint ch) { return yxml_refend(x, YXML_CONTENT); }
yxml_ret_t yxml_refattrval(yxml_t *x, uint ch) { return yxml_refend(x, YXML_ATTRVAL); }

void yxml_init(yxml_t *x, void *stack, size_t stacksize) 
{
    memset(x, 0, (*x).sizeof);
    x.line = 1;
    x.stack = cast(char*)stack;
    x.stacksize = stacksize;
    *x.stack = 0;
    x.elem = x.pi = x.attr = cast(char *)x.stack;
    x.state = YXMLS_init;
}

yxml_ret_t yxml_parse(yxml_t *x, int _ch) 
{
    /* Ensure that characters are in the range of 0..255 rather than -126..125.
     * All character comparisons are done with positive integers. */
    uint ch = cast(uint)(_ch+256) & 0xff;
    if(!ch)
        return YXML_ESYN;
    x.total++;

    /* End-of-Line normalization, "\rX", "\r\n" and "\n" are recognized and
     * normalized to a single '\n' as per XML 1.0 section 2.11. XML 1.1 adds
     * some non-ASCII character sequences to this list, but we can only handle
     * ASCII here without making assumptions about the input encoding. */
    if(x.ignore == ch) 
    {
        x.ignore = 0;
        return YXML_OK;
    }
    x.ignore = (ch == 0xd) * 0xa;
    if(ch == 0xa || ch == 0xd) {
        ch = 0xa;
        x.line++;
        x.byte_ = 0;
    }
    x.byte_++;

    switch(cast(yxml_state_t)x.state) 
    {
    case YXMLS_string:
        if(ch == *x.string_) {
            x.string_++;
            if(!*x.string_)
                x.state = x.nextstate;
            return YXML_OK;
        }
        break;
    case YXMLS_attr0:
        if(yxml_isName(cast(char)ch))
            return yxml_attrname(x, ch);
        if(yxml_isSP(cast(char)ch)) {
            x.state = YXMLS_attr1;
            return yxml_attrnameend(x, ch);
        }
        if(ch == '=') {
            x.state = YXMLS_attr2;
            return yxml_attrnameend(x, ch);
        }
        break;
    case YXMLS_attr1:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '=') {
            x.state = YXMLS_attr2;
            return YXML_OK;
        }
        break;
    case YXMLS_attr2:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '\'' || ch == '"') {
            x.state = YXMLS_attr3;
            x.quote = ch;
            return YXML_OK;
        }
        break;
    case YXMLS_attr3:
        if(yxml_isAttValue(x, cast(char)ch))
            return yxml_dataattr(x, ch);
        if(ch == '&') {
            x.state = YXMLS_attr4;
            return yxml_refstart(x, ch);
        }
        if(x.quote == ch) {
            x.state = YXMLS_elem2;
            return yxml_attrvalend(x, ch);
        }
        break;
    case YXMLS_attr4:
        if(yxml_isRef(cast(char)ch))
            return yxml_ref(x, ch);
        if(ch == '\x3b') {
            x.state = YXMLS_attr3;
            return yxml_refattrval(x, ch);
        }
        break;
    case YXMLS_cd0:
        if(ch == ']') {
            x.state = YXMLS_cd1;
            return YXML_OK;
        }
        if(yxml_isChar(cast(char)ch))
            return yxml_datacontent(x, ch);
        break;
    case YXMLS_cd1:
        if(ch == ']') {
            x.state = YXMLS_cd2;
            return YXML_OK;
        }
        if(yxml_isChar(cast(char)ch)) {
            x.state = YXMLS_cd0;
            return yxml_datacd1(x, ch);
        }
        break;
    case YXMLS_cd2:
        if(ch == ']')
            return yxml_datacontent(x, ch);
        if(ch == '>') {
            x.state = YXMLS_misc2;
            return YXML_OK;
        }
        if(yxml_isChar(cast(char)ch)) {
            x.state = YXMLS_cd0;
            return yxml_datacd2(x, ch);
        }
        break;
    case YXMLS_comment0:
        if(ch == '-') {
            x.state = YXMLS_comment1;
            return YXML_OK;
        }
        break;
    case YXMLS_comment1:
        if(ch == '-') {
            x.state = YXMLS_comment2;
            return YXML_OK;
        }
        break;
    case YXMLS_comment2:
        if(ch == '-') {
            x.state = YXMLS_comment3;
            return YXML_OK;
        }
        if(yxml_isChar(cast(char)ch))
            return YXML_OK;
        break;
    case YXMLS_comment3:
        if(ch == '-') {
            x.state = YXMLS_comment4;
            return YXML_OK;
        }
        if(yxml_isChar(cast(char)ch)) {
            x.state = YXMLS_comment2;
            return YXML_OK;
        }
        break;
    case YXMLS_comment4:
        if(ch == '>') {
            x.state = x.nextstate;
            return YXML_OK;
        }
        break;
    case YXMLS_dt0:
        if(ch == '>') {
            x.state = YXMLS_misc1;
            return YXML_OK;
        }
        if(ch == '\'' || ch == '"') {
            x.state = YXMLS_dt1;
            x.quote = ch;
            x.nextstate = YXMLS_dt0;
            return YXML_OK;
        }
        if(ch == '<') {
            x.state = YXMLS_dt2;
            return YXML_OK;
        }
        if(yxml_isChar(cast(char)ch))
            return YXML_OK;
        break;
    case YXMLS_dt1:
        if(x.quote == ch) {
            x.state = x.nextstate;
            return YXML_OK;
        }
        if(yxml_isChar(cast(char)ch))
            return YXML_OK;
        break;
    case YXMLS_dt2:
        if(ch == '?') {
            x.state = YXMLS_pi0;
            x.nextstate = YXMLS_dt0;
            return YXML_OK;
        }
        if(ch == '!') {
            x.state = YXMLS_dt3;
            return YXML_OK;
        }
        break;
    case YXMLS_dt3:
        if(ch == '-') {
            x.state = YXMLS_comment1;
            x.nextstate = YXMLS_dt0;
            return YXML_OK;
        }
        if(yxml_isChar(cast(char)ch)) {
            x.state = YXMLS_dt4;
            return YXML_OK;
        }
        break;
    case YXMLS_dt4:
        if(ch == '\'' || ch == '"') {
            x.state = YXMLS_dt1;
            x.quote = ch;
            x.nextstate = YXMLS_dt4;
            return YXML_OK;
        }
        if(ch == '>') {
            x.state = YXMLS_dt0;
            return YXML_OK;
        }
        if(yxml_isChar(cast(char)ch))
            return YXML_OK;
        break;
    case YXMLS_elem0:
        if(yxml_isName(cast(char)ch))
            return yxml_elemname(x, ch);
        if(yxml_isSP(cast(char)ch)) {
            x.state = YXMLS_elem1;
            return yxml_elemnameend(x, ch);
        }
        if(ch == '/') {
            x.state = YXMLS_elem3;
            return yxml_elemnameend(x, ch);
        }
        if(ch == '>') {
            x.state = YXMLS_misc2;
            return yxml_elemnameend(x, ch);
        }
        break;
    case YXMLS_elem1:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '/') {
            x.state = YXMLS_elem3;
            return YXML_OK;
        }
        if(ch == '>') {
            x.state = YXMLS_misc2;
            return YXML_OK;
        }
        if(yxml_isNameStart(cast(char)ch)) {
            x.state = YXMLS_attr0;
            return yxml_attrstart(x, ch);
        }
        break;
    case YXMLS_elem2:
        if(yxml_isSP(cast(char)ch)) {
            x.state = YXMLS_elem1;
            return YXML_OK;
        }
        if(ch == '/') {
            x.state = YXMLS_elem3;
            return YXML_OK;
        }
        if(ch == '>') {
            x.state = YXMLS_misc2;
            return YXML_OK;
        }
        break;
    case YXMLS_elem3:
        if(ch == '>') {
            x.state = YXMLS_misc2;
            return yxml_selfclose(x, ch);
        }
        break;
    case YXMLS_enc0:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '=') {
            x.state = YXMLS_enc1;
            return YXML_OK;
        }
        break;
    case YXMLS_enc1:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '\'' || ch == '"') {
            x.state = YXMLS_enc2;
            x.quote = ch;
            return YXML_OK;
        }
        break;
    case YXMLS_enc2:
        if(yxml_isAlpha(cast(char)ch)) {
            x.state = YXMLS_enc3;
            return YXML_OK;
        }
        break;
    case YXMLS_enc3:
        if(yxml_isEncName(cast(char)ch))
            return YXML_OK;
        if(x.quote == ch) {
            x.state = YXMLS_xmldecl6;
            return YXML_OK;
        }
        break;
    case YXMLS_etag0:
        if(yxml_isNameStart(cast(char)ch)) {
            x.state = YXMLS_etag1;
            return yxml_elemclose(x, ch);
        }
        break;
    case YXMLS_etag1:
        if(yxml_isName(cast(char)ch))
            return yxml_elemclose(x, ch);
        if(yxml_isSP(cast(char)ch)) {
            x.state = YXMLS_etag2;
            return yxml_elemcloseend(x, ch);
        }
        if(ch == '>') {
            x.state = YXMLS_misc2;
            return yxml_elemcloseend(x, ch);
        }
        break;
    case YXMLS_etag2:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '>') {
            x.state = YXMLS_misc2;
            return YXML_OK;
        }
        break;
    case YXMLS_init:
        if(ch == '\xef') {
            x.state = YXMLS_string;
            x.nextstate = YXMLS_misc0;
            x.string_ = "\xbb\xbf".ptr;
            return YXML_OK;
        }
        if(yxml_isSP(cast(char)ch)) {
            x.state = YXMLS_misc0;
            return YXML_OK;
        }
        if(ch == '<') {
            x.state = YXMLS_le0;
            return YXML_OK;
        }
        break;
    case YXMLS_le0:
        if(ch == '!') {
            x.state = YXMLS_lee1;
            return YXML_OK;
        }
        if(ch == '?') {
            x.state = YXMLS_leq0;
            return YXML_OK;
        }
        if(yxml_isNameStart(cast(char)ch)) {
            x.state = YXMLS_elem0;
            return yxml_elemstart(x, ch);
        }
        break;
    case YXMLS_le1:
        if(ch == '!') {
            x.state = YXMLS_lee1;
            return YXML_OK;
        }
        if(ch == '?') {
            x.state = YXMLS_pi0;
            x.nextstate = YXMLS_misc1;
            return YXML_OK;
        }
        if(yxml_isNameStart(cast(char)ch)) {
            x.state = YXMLS_elem0;
            return yxml_elemstart(x, ch);
        }
        break;
    case YXMLS_le2:
        if(ch == '!') {
            x.state = YXMLS_lee2;
            return YXML_OK;
        }
        if(ch == '?') {
            x.state = YXMLS_pi0;
            x.nextstate = YXMLS_misc2;
            return YXML_OK;
        }
        if(ch == '/') {
            x.state = YXMLS_etag0;
            return YXML_OK;
        }
        if(yxml_isNameStart(cast(char)ch)) {
            x.state = YXMLS_elem0;
            return yxml_elemstart(x, ch);
        }
        break;
    case YXMLS_le3:
        if(ch == '!') {
            x.state = YXMLS_comment0;
            x.nextstate = YXMLS_misc3;
            return YXML_OK;
        }
        if(ch == '?') {
            x.state = YXMLS_pi0;
            x.nextstate = YXMLS_misc3;
            return YXML_OK;
        }
        break;
    case YXMLS_lee1:
        if(ch == '-') {
            x.state = YXMLS_comment1;
            x.nextstate = YXMLS_misc1;
            return YXML_OK;
        }
        if(ch == 'D') {
            x.state = YXMLS_string;
            x.nextstate = YXMLS_dt0;
            x.string_ = "OCTYPE".ptr;
            return YXML_OK;
        }
        break;
    case YXMLS_lee2:
        if(ch == '-') {
            x.state = YXMLS_comment1;
            x.nextstate = YXMLS_misc2;
            return YXML_OK;
        }
        if(ch == '[') {
            x.state = YXMLS_string;
            x.nextstate = YXMLS_cd0;
            x.string_ = "CDATA[".ptr;
            return YXML_OK;
        }
        break;
    case YXMLS_leq0:
        if(ch == 'x') {
            x.state = YXMLS_xmldecl0;
            x.nextstate = YXMLS_misc1;
            return yxml_pistart(x, ch);
        }
        if(yxml_isNameStart(cast(char)ch)) {
            x.state = YXMLS_pi1;
            x.nextstate = YXMLS_misc1;
            return yxml_pistart(x, ch);
        }
        break;
    case YXMLS_misc0:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '<') {
            x.state = YXMLS_le0;
            return YXML_OK;
        }
        break;
    case YXMLS_misc1:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '<') {
            x.state = YXMLS_le1;
            return YXML_OK;
        }
        break;
    case YXMLS_misc2:
        if(ch == '<') {
            x.state = YXMLS_le2;
            return YXML_OK;
        }
        if(ch == '&') {
            x.state = YXMLS_misc2a;
            return yxml_refstart(x, ch);
        }
        if(yxml_isChar(cast(char)ch))
            return yxml_datacontent(x, ch);
        break;
    case YXMLS_misc2a:
        if(yxml_isRef(cast(char)ch))
            return yxml_ref(x, ch);
        if(ch == '\x3b') {
            x.state = YXMLS_misc2;
            return yxml_refcontent(x, ch);
        }
        break;
    case YXMLS_misc3:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '<') {
            x.state = YXMLS_le3;
            return YXML_OK;
        }
        break;
    case YXMLS_pi0:
        if(yxml_isNameStart(cast(char)ch)) {
            x.state = YXMLS_pi1;
            return yxml_pistart(x, ch);
        }
        break;
    case YXMLS_pi1:
        if(yxml_isName(cast(char)ch))
            return yxml_piname(x, ch);
        if(ch == '?') {
            x.state = YXMLS_pi4;
            return yxml_pinameend(x, ch);
        }
        if(yxml_isSP(cast(char)ch)) {
            x.state = YXMLS_pi2;
            return yxml_pinameend(x, ch);
        }
        break;
    case YXMLS_pi2:
        if(ch == '?') {
            x.state = YXMLS_pi3;
            return YXML_OK;
        }
        if(yxml_isChar(cast(char)ch))
            return yxml_datapi1(x, ch);
        break;
    case YXMLS_pi3:
        if(ch == '>') {
            x.state = x.nextstate;
            return yxml_pivalend(x, ch);
        }
        if(yxml_isChar(cast(char)ch)) {
            x.state = YXMLS_pi2;
            return yxml_datapi2(x, ch);
        }
        break;
    case YXMLS_pi4:
        if(ch == '>') {
            x.state = x.nextstate;
            return yxml_pivalend(x, ch);
        }
        break;
    case YXMLS_std0:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '=') {
            x.state = YXMLS_std1;
            return YXML_OK;
        }
        break;
    case YXMLS_std1:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '\'' || ch == '"') {
            x.state = YXMLS_std2;
            x.quote = ch;
            return YXML_OK;
        }
        break;
    case YXMLS_std2:
        if(ch == 'y') {
            x.state = YXMLS_string;
            x.nextstate = YXMLS_std3;
            x.string_ = "es".ptr;
            return YXML_OK;
        }
        if(ch == 'n') {
            x.state = YXMLS_string;
            x.nextstate = YXMLS_std3;
            x.string_ = "o".ptr;
            return YXML_OK;
        }
        break;
    case YXMLS_std3:
        if(x.quote == ch) {
            x.state = YXMLS_xmldecl8;
            return YXML_OK;
        }
        break;
    case YXMLS_ver0:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '=') {
            x.state = YXMLS_ver1;
            return YXML_OK;
        }
        break;
    case YXMLS_ver1:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '\'' || ch == '"') {
            x.state = YXMLS_string;
            x.quote = ch;
            x.nextstate = YXMLS_ver2;
            x.string_ = "1.".ptr;
            return YXML_OK;
        }
        break;
    case YXMLS_ver2:
        if(yxml_isNum(cast(char)ch)) {
            x.state = YXMLS_ver3;
            return YXML_OK;
        }
        break;
    case YXMLS_ver3:
        if(yxml_isNum(cast(char)ch))
            return YXML_OK;
        if(x.quote == ch) {
            x.state = YXMLS_xmldecl4;
            return YXML_OK;
        }
        break;
    case YXMLS_xmldecl0:
        if(ch == 'm') {
            x.state = YXMLS_xmldecl1;
            return yxml_piname(x, ch);
        }
        if(yxml_isName(cast(char)ch)) {
            x.state = YXMLS_pi1;
            return yxml_piname(x, ch);
        }
        if(ch == '?') {
            x.state = YXMLS_pi4;
            return yxml_pinameend(x, ch);
        }
        if(yxml_isSP(cast(char)ch)) {
            x.state = YXMLS_pi2;
            return yxml_pinameend(x, ch);
        }
        break;
    case YXMLS_xmldecl1:
        if(ch == 'l') {
            x.state = YXMLS_xmldecl2;
            return yxml_piname(x, ch);
        }
        if(yxml_isName(cast(char)ch)) {
            x.state = YXMLS_pi1;
            return yxml_piname(x, ch);
        }
        if(ch == '?') {
            x.state = YXMLS_pi4;
            return yxml_pinameend(x, ch);
        }
        if(yxml_isSP(cast(char)ch)) {
            x.state = YXMLS_pi2;
            return yxml_pinameend(x, ch);
        }
        break;
    case YXMLS_xmldecl2:
        if(yxml_isSP(cast(char)ch)) {
            x.state = YXMLS_xmldecl3;
            return yxml_piabort(x, ch);
        }
        if(yxml_isName(cast(char)ch)) {
            x.state = YXMLS_pi1;
            return yxml_piname(x, ch);
        }
        break;
    case YXMLS_xmldecl3:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == 'v') {
            x.state = YXMLS_string;
            x.nextstate = YXMLS_ver0;
            x.string_ = "ersion".ptr;
            return YXML_OK;
        }
        break;
    case YXMLS_xmldecl4:
        if(yxml_isSP(cast(char)ch)) {
            x.state = YXMLS_xmldecl5;
            return YXML_OK;
        }
        if(ch == '?') {
            x.state = YXMLS_xmldecl9;
            return YXML_OK;
        }
        break;
    case YXMLS_xmldecl5:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '?') {
            x.state = YXMLS_xmldecl9;
            return YXML_OK;
        }
        if(ch == 'e') {
            x.state = YXMLS_string;
            x.nextstate = YXMLS_enc0;
            x.string_ = "ncoding".ptr;
            return YXML_OK;
        }
        if(ch == 's') {
            x.state = YXMLS_string;
            x.nextstate = YXMLS_std0;
            x.string_ = "tandalone".ptr;
            return YXML_OK;
        }
        break;
    case YXMLS_xmldecl6:
        if(yxml_isSP(cast(char)ch)) {
            x.state = YXMLS_xmldecl7;
            return YXML_OK;
        }
        if(ch == '?') {
            x.state = YXMLS_xmldecl9;
            return YXML_OK;
        }
        break;
    case YXMLS_xmldecl7:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '?') {
            x.state = YXMLS_xmldecl9;
            return YXML_OK;
        }
        if(ch == 's') {
            x.state = YXMLS_string;
            x.nextstate = YXMLS_std0;
            x.string_ = "tandalone".ptr;
            return YXML_OK;
        }
        break;
    case YXMLS_xmldecl8:
        if(yxml_isSP(cast(char)ch))
            return YXML_OK;
        if(ch == '?') {
            x.state = YXMLS_xmldecl9;
            return YXML_OK;
        }
        break;
    case YXMLS_xmldecl9:
        if(ch == '>') {
            x.state = YXMLS_misc1;
            return YXML_OK;
        }
        break;
    default:
        assert(false);
    }
    return YXML_ESYN;
}


/* May be called after the last character has been given to yxml_parse().
* Returns YXML_OK if the XML document is valid, YXML_EEOF otherwise.  Using
* this function isn't really necessary, but can be used to detect documents
* that don't end correctly. In particular, an error is returned when the XML
* document did not contain a (complete) root element, or when the document
* ended while in a comment or processing instruction. */
yxml_ret_t yxml_eof(yxml_t *x) 
{
    if(x.state != YXMLS_misc3)
        return YXML_EEOF;
    return YXML_OK;
}

//
// </PARSER ENDS HERE>
//

nothrow @nogc unittest 
{
    XmlDocument doc;
    assert(doc.isError);
    doc.parse(`<?xml version="1.0" encoding="UTF-8" ?><root><test /><test/><test><inner></inner></test></root>`);
    assert(!doc.isError);
    XmlElement root = doc.root;
    assert(root.tagName == "root");
    assert(root.childNodes.length == 3);

    // check recursive search
    /*auto r = root.getElementsByTagName("inner");
    assert(!r.empty);
    r.popFront;
    assert(r.empty);*/
}

// .textContent
nothrow @nogc unittest 
{
    XmlDocument doc;
    doc.parse("<html>This is text <p>lol</p>content</html>");
    assert(!doc.isError);
    assert(doc.root.textContent == "This is text lolcontent");
}

// attributes
nothrow @nogc unittest 
{
    XmlDocument doc;
    doc.parse(`<stuff major="lol">hey</stuff>`);
    assert(!doc.isError);
    XmlElement e = doc.root;
    assert(e.tagName == "stuff");
    assert(e.hasAttributes());
    XmlAttr attr = e.getAttributeNode("major");
    assert(attr !is null);
    assert(e.getAttributeNode("non-existing") is null);
    auto r = e.attributes;
    assert(r.length == 1);
    assert(r.front().name() == "major");
    assert(r.front().value() == "lol");
}

// .innerHTML
nothrow @nogc unittest 
{
    XmlDocument doc;
    doc.parse("<html>This is innerHTML <b id=\"lol\">get</b> property</html>");
    assert(!doc.isError);
    assert(doc.root.innerHTML == "This is innerHTML <b id=\"lol\">get</b> property");
}

nothrow @nogc unittest 
{
    XmlDocument doc;
    doc.parse("<html><a> ah </a><b>oh</b></html>");
    assert(!doc.isError);
    XmlElement a = doc.root.firstChildByTagName("a");
    XmlElement b = doc.root.firstChildByTagName("b");
    assert(a !is null);
    assert(b !is null);
    assert(a.textContent == " ah ");
    assert(b.textContent == "oh");
}

// TODO: Test using doc instead of doc.root for `XmlElement` calls.
nothrow @nogc unittest
{
    import std.conv;
    import std.stdio;

    const(char)[] parseMyXMLData(const(char)[] xmlData) nothrow @nogc
    {
        // Parse a whole XML file, builds a DOM.
        XmlDocument doc;
        doc.parse(xmlData);

        assert(!doc.isError);

        XmlElement root = doc.root;

        if (root.tagName != "results")
            assert(false);

        foreach(e; root.getChildrenByTagName("metric"))
        {
            if (!e.hasAttribute("value"))
                assert(false);
            return e.getAttribute("value");
        }
        assert(false);
    }

    assert("5.8" == parseMyXMLData(`<?xml version="1.0" encoding="UTF-8"?><results><metric value="5.8" /></results>`));    
}