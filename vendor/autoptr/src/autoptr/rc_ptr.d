/**
    Implementation of reference counted pointer `RcPtr` (similar to c++ `std::shared_ptr` without aliasing).

    License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
    Authors:   $(HTTP github.com/submada/basic_string, Adam Búš)
*/
module autoptr.rc_ptr;

import autoptr.internal.mallocator : Mallocator;
import autoptr.internal.traits;

import autoptr.common;
import autoptr.unique_ptr : UniquePtr, isUniquePtr, isValidUniquePtr;



/**
    Check if type `T` is `RcPtr` and has valid type qualifiers.
*/
public template isValidRcPtr(T){
    import std.traits : Unqual;

    static if(is(Unqual!T == RcPtr!Args, Args...))
        enum bool impl = true
            && (!is(T == shared) || is(T.ControlType == shared));
    else
        enum bool impl = false;

    enum bool isValidRcPtr = impl;
    
}

///
unittest{
    static assert(!isValidRcPtr!long);
    static assert(!isValidRcPtr!(void*));

    static assert(isValidRcPtr!(RcPtr!long));
    static assert(isValidRcPtr!(RcPtr!long.WeakType));

    static assert(!isValidRcPtr!(shared(RcPtr!long)));
    static assert(isValidRcPtr!(shared(RcPtr!(shared long))));
}


/**
    Check if type `T` is `RcPtr`.
*/
public template isRcPtr(T){
    import std.traits : Unqual;

    enum bool isRcPtr = is(Unqual!T == RcPtr!Args, Args...);
}

///
unittest{
    static assert(!isRcPtr!long);
    static assert(!isRcPtr!(void*));

    static assert(isRcPtr!(RcPtr!long));
    static assert(isRcPtr!(RcPtr!long.WeakType));
}



/**
    `RcPtr` is a smart pointer that retains shared ownership of an object through a pointer.

    Several `RcPtr` objects may own the same object.

    The object is destroyed and its memory deallocated when either of the following happens:

        1. the last remaining `RcPtr` owning the object is destroyed.

        2. the last remaining `RcPtr` owning the object is assigned another pointer via various methods like `opAssign` and `store`.

    The object is destroyed using destructor of type `_Type`.

    A `RcPtr` can not share ownership of an object while storing a pointer to another object (use `SharedPtr` for that).
    The stored pointer is the one accessed by `get()`, the dereference and the comparison operators.

    A `RcPtr` may also own no objects, in which case it is called empty.

    If template parameter `_ControlType` is `shared`  then all member functions (including copy constructor and copy assignment)
    can be called by multiple threads on different instances of `RcPtr` without additional synchronization even if these instances are copies and share ownership of the same object.

    If multiple threads of execution access the same `RcPtr` (`shared RcPtr`) then only some methods can be called (`load`, `store`, `exchange`, `compareExchange`, `useCount`).

    Template parameters:

        `_Type` type of managed object

        `_DestructorType` function pointer with attributes of destructor, to get attributes of destructor from type use `autoptr.common.DestructorType!T`. Destructor of type `_Type` must be compatible with `_DestructorType`

        `_ControlType` represent type of counter, must by of type `autoptr.common.ControlBlock`. if is shared then ref counting is atomic.

        `_weakPtr` if `true` then `RcPtr` represent weak ptr

*/
public template RcPtr(
    _Type,
    _DestructorType = DestructorType!_Type,
    _ControlType = ControlTypeDeduction!(_Type, SharedControlType),
    bool _weakPtr = false
)
if(isControlBlock!_ControlType && isDestructorType!_DestructorType){
    static assert(isMutable!_ControlType);
    static assert(_ControlType.hasSharedCounter);


    static if(_weakPtr)
    static assert(_ControlType.hasWeakCounter);


    static assert(is(DestructorType!void : _DestructorType),
        _Type.stringof ~ " wrong DestructorType " ~ DestructorType!void.stringof ~
        " : " ~ _DestructorType.stringof
    );

    static assert(is(DestructorType!_Type : _DestructorType),
        "destructor of type '" ~ _Type.stringof ~
        "' doesn't support specified finalizer " ~ _DestructorType.stringof
    );

    static if (is(_Type == class) || is(_Type == interface) || is(_Type == struct) || is(_Type == union))
        static assert(!__traits(isNested, _Type), "RcPtr does not support nested types.");


    import std.experimental.allocator : stateSize;
    import std.meta : AliasSeq;
    import std.range : ElementEncodingType;
    import std.traits: Unqual, Unconst, CopyTypeQualifiers, CopyConstness,
        hasIndirections, hasElaborateDestructor,
        isMutable, isAbstractClass, isDynamicArray, isStaticArray, isCallable, Select, isArray;

    import core.atomic : MemoryOrder;
    import core.lifetime : forward;


    enum bool hasWeakCounter = _ControlType.hasWeakCounter;

    enum bool hasSharedCounter = _ControlType.hasSharedCounter;

    enum bool referenceElementType = isReferenceType!_Type || isDynamicArray!_Type;

    static assert(!isIntrusive!_Type);


    enum bool _isLockFree = !isDynamicArray!_Type;

    struct RcPtr{
        /**
            Type of element managed by `RcPtr`.
        */
        public alias ElementType = _Type;


        /**
            Type of destructor (`void function(void*)@attributes`).
        */
        public alias DestructorType = _DestructorType;


        /**
            Type of control block.
        */
        public alias ControlType = _ControlType;


        /**
            `true` if `RcPtr` is weak ptr.
        */
        public enum bool weakPtr = _weakPtr;


        /**
            Same as `ElementType*` or `ElementType` if is class/interface/slice.
        */
        public alias ElementReferenceType = ElementReferenceTypeImpl!ElementType;


        /**
            Weak pointer

            `RcPtr.WeakType` is a smart pointer that holds a non-owning ("weak") reference to an object that is managed by `RcPtr`.
            It must be converted to `RcPtr` in order to access the referenced object.

            `RcPtr.WeakType` models temporary ownership: when an object needs to be accessed only if it exists, and it may be deleted at any time by someone else,
            `RcPtr.WeakType` is used to track the object, and it is converted to `RcPtr` to assume temporary ownership.
            If the original `RcPtr` is destroyed at this time, the object's lifetime is extended until the temporary `RcPtr` is destroyed as well.

            Another use for `RcPtr.WeakType` is to break reference cycles formed by objects managed by `RcPtr`.
            If such cycle is orphaned (i,e. there are no outside shared pointers into the cycle), the `RcPtr` reference counts cannot reach zero and the memory is leaked.
            To prevent this, one of the pointers in the cycle can be made weak.
        */
        static if(hasWeakCounter && !weakPtr)
        public alias WeakType = RcPtr!(
            _Type,
            _DestructorType,
            _ControlType,
            true
        );


        /**
            Type of non weak ptr (must have weak counter).
        */
        static if(weakPtr)
        public alias SharedType = RcPtr!(
            _Type,
            _DestructorType,
            _ControlType,
            false
        );


        /**
            Return thhread local `RcPtr` if specified:

                1.  if parameter `threadLocal` is `true` then result type is thread local `RcPtr` (!is(_ControlType == shared)).

                2.  if parameter `threadLocal` is `false` then result type is not thread local `RcPtr` (is(_ControlType == shared)).
        */
        public template ThreadLocal(bool threadLocal = true){
            static if(threadLocal)
                alias ThreadLocal = RcPtr!(
                    _Type,
                    _DestructorType,
                    Unqual!_ControlType,
                    weakPtr
                );
            else
                alias ThreadLocal = RcPtr!(
                    _Type,
                    _DestructorType,
                    shared(_ControlType),
                    weakPtr
                );
        }


        /**
            `true` if shared `RcPtr` has lock free operations `store`, `load`, `exchange`, `compareExchange`, otherwise 'false'
        */
        public alias isLockFree = _isLockFree;

        static if(isLockFree)
        static assert(ElementReferenceType.sizeof == size_t.sizeof);



        /**
            Destructor

            If `this` owns an object and it is the last `RcPtr` owning it, the object is destroyed.
            After the destruction, the smart pointers that shared ownership with `this`, if any, will report a `useCount()` that is one less than its previous value.
        */
        public ~this(){
            this._release();
        }


        //necesary for autoptr.unique_ptr.sharedPtr
        package this(Elm, this This)(Elm element, Evoid ctor)pure nothrow @safe @nogc
        if(true
            && is(Elm : GetElementReferenceType!This) 
            && !is(Unqual!Elm == typeof(null))
        ){
            this._element = element;
        }

        //
        package this(Elm, this This)(ControlType* control, Elm element)pure nothrow @safe @nogc
        if(true
            && is(Elm : GetElementReferenceType!This) 
            && !is(Unqual!Elm == typeof(null))
        ){
            assert(control !is null);
            assert((control is null) == (element is null));

            this(element, Evoid.init);
            control.add!weakPtr;
        }

        //copy ctor
        package this(Rhs, this This)(ref scope Rhs rhs, Evoid ctor)@trusted
        if(true
            && isRcPtr!Rhs
            && isConstructable!(Rhs, This)
            && !weakLock!(Rhs, This)
            && !is(Rhs == shared)
        ){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");
            static assert(isValidRcPtr!Rhs, "`Rhs` is invalid `RcPtr`");

            if(rhs._element is null)
                this(null);
            else
                this(rhs._control, rhs._element);
        }


        /**
            Constructs a `RcPtr` without managed object. Same as `RcPtr.init`

            Examples:
                --------------------
                RcPtr!long x = null;

                assert(x == null);
                assert(x == RcPtr!long.init);
                --------------------
        */
        public this(this This)(typeof(null) nil)pure nothrow @safe @nogc{
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");
        }



        /**
            Constructs a `RcPtr` which shares ownership of the object managed by `rhs`.

            If rhs manages no object, this manages no object too.
            If rhs if rvalue then ownership is moved.
            The template overload doesn't participate in overload resolution if ElementType of `typeof(rhs)` is not implicitly convertible to `ElementType`.
            If rhs if `WeakType` then this ctor is equivalent to `this(rhs.lock())`.

            Examples:
                --------------------
                {
                    RcPtr!long x = RcPtr!long.make(123);
                    assert(x.useCount == 1);

                    RcPtr!long a = x;         //lvalue copy ctor
                    assert(a == x);

                    const RcPtr!long b = x;   //lvalue copy ctor
                    assert(b == x);

                    RcPtr!(const long) c = x; //lvalue ctor
                    assert(c == x);

                    const RcPtr!long d = b;   //lvalue ctor
                    assert(d == x);

                    assert(x.useCount == 5);
                }

                {
                    import core.lifetime : move;
                    RcPtr!long x = RcPtr!long.make(123);
                    assert(x.useCount == 1);

                    RcPtr!long a = move(x);        //rvalue copy ctor
                    assert(a.useCount == 1);

                    const RcPtr!long b = move(a);  //rvalue copy ctor
                    assert(b.useCount == 1);

                    RcPtr!(const long) c = b.load;  //rvalue ctor
                    assert(c.useCount == 2);

                    const RcPtr!long d = move(c);  //rvalue ctor
                    assert(d.useCount == 2);
                }

                {
                    import core.lifetime : move;
                    auto u = UniquePtr!(long, SharedControlType).make(123);

                    RcPtr!long s = move(u);        //rvalue copy ctor
                    assert(s != null);
                    assert(s.useCount == 1);

                    RcPtr!long s2 = UniquePtr!(long, SharedControlType).init;
                    assert(s2 == null);
                }
                --------------------
        */
        public this(Rhs, this This)(ref scope Rhs rhs)@trusted
        if(true
            && isRcPtr!Rhs
            && !is(Unqual!This == Unqual!Rhs)   ///copy ctors
            && isConstructable!(Rhs, This)
            && !weakLock!(Rhs, This)
            && !is(Rhs == shared)
        ){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");
            static assert(isValidRcPtr!Rhs, "`Rhs` is invalid `RcPtr`");

            this(rhs, Evoid.init);
        }

        /// ditto
        public this(Rhs, this This)(scope Rhs rhs)@trusted
        if(true
            && isRcPtr!Rhs
            //&& !is(Unqual!This == Unqual!Rhs) //TODO move ctors need this
            && isConstructable!(Rhs, This)
            && !weakLock!(Rhs, This)
            && !is(Rhs == shared)
        ){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");
            static assert(isValidRcPtr!Rhs, "`Rhs` is invalid `RcPtr`");

            this._element = rhs._element;
            rhs._const_reset();
        }

        /// ditto
        public this(Rhs, this This)(auto ref scope Rhs rhs)@trusted
        if(true
            && isRcPtr!Rhs
            && isConstructable!(Rhs, This)
            && weakLock!(Rhs, This)
            && !is(Rhs == shared)
        ){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");
            static assert(isValidRcPtr!Rhs, "`Rhs` is invalid `RcPtr`");

            if(rhs._element !is null && rhs._control.add_shared_if_exists())
                this._element = rhs._element;
            else
                this._element = null;
        }

        /// ditto
        public this(Rhs, this This)(scope Rhs rhs)@trusted
        if(true
            && isUniquePtr!Rhs
            && isConstructable!(Rhs, This)
            && !is(Rhs == shared)
        ){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");
            static assert(isValidUniquePtr!Rhs, "`Rhs` is invalid `Unique`");

            if(rhs == null){
                this(null);
            }
            else{
                this(rhs.element, Evoid.init);
                rhs._const_reset();
            }
        }



        //copy ctors:
        //mutable:
        static if(is(Unqual!ElementType == ElementType)){
            //mutable rhs:
            this(ref scope typeof(this) rhs)@trusted{this(rhs, Evoid.init);}
            this(ref scope typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            @disable this(ref scope typeof(this) rhs)immutable @safe;
            @disable this(ref scope typeof(this) rhs)shared @safe;
            @disable this(ref scope typeof(this) rhs)const shared @safe;

            //const rhs:
            @disable this(ref scope const typeof(this) rhs)@safe;
            this(ref scope const typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            @disable this(ref scope const typeof(this) rhs)immutable @safe;
            @disable this(ref scope const typeof(this) rhs)shared @safe;
            @disable this(ref scope const typeof(this) rhs)const shared @safe;

            //immutable(Ptr) iptr;
            @disable this(ref scope immutable typeof(this) rhs)@safe;
            this(ref scope immutable typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            this(ref scope immutable typeof(this) rhs)immutable @trusted{this(rhs, Evoid.init);}
            @disable this(ref scope immutable typeof(this) rhs)shared @safe;
            static if(is(ControlType == shared))
                this(ref scope immutable typeof(this) rhs)const shared @trusted{this(rhs, Evoid.init);}
            else
                @disable this(ref scope immutable typeof(this) rhs)const shared @safe;

        }
        //const:
        else static if(is(const Unqual!ElementType == ElementType)){
            //mutable rhs:
            this(ref scope typeof(this) rhs)@trusted{this(rhs, Evoid.init);}
            this(ref scope typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            @disable this(ref scope typeof(this) rhs)immutable @safe;
            @disable this(ref scope typeof(this) rhs)shared @safe;
            @disable this(ref scope typeof(this) rhs)const shared @safe;

            //const rhs:
            this(ref scope const typeof(this) rhs)@trusted{this(rhs, Evoid.init);}
            this(ref scope const typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            @disable this(ref scope const typeof(this) rhs)immutable @safe;
            @disable this(ref scope const typeof(this) rhs)shared @safe;
            @disable this(ref scope const typeof(this) rhs)const shared @safe;

            //immutable rhs:
            this(ref scope immutable typeof(this) rhs)@trusted{this(rhs, Evoid.init);}
            this(ref scope immutable typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            this(ref scope immutable typeof(this) rhs)immutable @trusted{this(rhs, Evoid.init);}
            static if(is(ControlType == shared)){
                this(ref scope immutable typeof(this) rhs)shared @trusted{this(rhs, Evoid.init);}
                this(ref scope immutable typeof(this) rhs)const shared @trusted{this(rhs, Evoid.init);}
            }
            else{
                @disable this(ref scope immutable typeof(this) rhs)shared @safe;
                @disable this(ref scope immutable typeof(this) rhs)const shared @safe;
            }
        }
        //immutable:
        else static if(is(immutable Unqual!ElementType == ElementType)){
            //mutable rhs:
            this(ref scope typeof(this) rhs)@trusted{this(rhs, Evoid.init);}
            this(ref scope typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            this(ref scope typeof(this) rhs)immutable @trusted{this(rhs, Evoid.init);}
            static if(is(ControlType == shared)){
                this(ref scope typeof(this) rhs)shared @trusted{this(rhs, Evoid.init);}
                this(ref scope typeof(this) rhs)const shared @trusted{this(rhs, Evoid.init);}
            }
            else{
                @disable this(ref scope typeof(this) rhs)shared @safe;
                @disable this(ref scope typeof(this) rhs)const shared @safe;
            }

            //const rhs:
            this(ref scope const typeof(this) rhs)@trusted{this(rhs, Evoid.init);}
            this(ref scope const typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            this(ref scope const typeof(this) rhs)immutable @trusted{this(rhs, Evoid.init);}	//??
            static if(is(ControlType == shared)){
                this(ref scope const typeof(this) rhs)shared @trusted{this(rhs, Evoid.init);}
                this(ref scope const typeof(this) rhs)const shared @trusted{this(rhs, Evoid.init);}
            }
            else{
                @disable this(ref scope const typeof(this) rhs)shared @safe;
                @disable this(ref scope const typeof(this) rhs)const shared @safe;
            }

            //immutable rhs:
            this(ref scope immutable typeof(this) rhs)@trusted{this(rhs, Evoid.init);}	//??
            this(ref scope immutable typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            this(ref scope immutable typeof(this) rhs)immutable @trusted{this(rhs, Evoid.init);}
            static if(is(ControlType == shared)){
                this(ref scope immutable typeof(this) rhs)shared @trusted{this(rhs, Evoid.init);}
                this(ref scope immutable typeof(this) rhs)const shared @trusted{this(rhs, Evoid.init);}
            }
            else{
                @disable this(ref scope immutable typeof(this) rhs)shared @safe;
                @disable this(ref scope immutable typeof(this) rhs)const shared @safe;
            }
        }
        //shared:
        else static if(is(shared Unqual!ElementType == ElementType)){
            //static assert(!threadLocal);

            //mutable rhs:
            this(ref scope typeof(this) rhs)@trusted{this(rhs, Evoid.init);}
            this(ref scope typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            @disable this(ref scope typeof(this) rhs)immutable @safe;
            static if(is(ControlType == shared)){
                this(ref scope typeof(this) rhs)shared @trusted{this(rhs, Evoid.init);}
                this(ref scope typeof(this) rhs)const shared @trusted{this(rhs, Evoid.init);}
            }
            else{
                @disable this(ref scope typeof(this) rhs)shared @safe;
                @disable this(ref scope typeof(this) rhs)const shared @safe;
            }

            //const rhs:
            @disable this(ref scope const typeof(this) rhs)@safe;
            this(ref scope const typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            @disable this(ref scope const typeof(this) rhs)immutable @safe;
            @disable this(ref scope const typeof(this) rhs)shared @safe;
            static if(is(ControlType == shared))
                this(ref scope const typeof(this) rhs)const shared @trusted{this(rhs, Evoid.init);}
            else
                @disable this(ref scope const typeof(this) rhs)const shared @safe;

            //immutable rhs:
            @disable this(ref scope immutable typeof(this) rhs)@safe;
            this(ref scope immutable typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            this(ref scope immutable typeof(this) rhs)immutable @trusted{this(rhs, Evoid.init);}
            @disable this(ref scope immutable typeof(this) rhs)shared @safe;
            static if(is(ControlType == shared))
                this(ref scope immutable typeof(this) rhs)const shared @trusted{this(rhs, Evoid.init);}
            else
                @disable this(ref scope immutable typeof(this) rhs)const shared @safe;
        }
        //shared const:
        else static if(is(const shared Unqual!ElementType == ElementType)){
            //static assert(!threadLocal);

            //mutable rhs:
            this(ref scope typeof(this) rhs)@trusted{this(rhs, Evoid.init);}
            this(ref scope typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            @disable this(ref scope typeof(this) rhs)immutable @safe;
            static if(is(ControlType == shared)){
                this(ref scope typeof(this) rhs)shared @trusted{this(rhs, Evoid.init);}
                this(ref scope typeof(this) rhs)const shared @trusted{this(rhs, Evoid.init);}
            }
            else{
                @disable this(ref scope typeof(this) rhs)shared @safe;
                @disable this(ref scope typeof(this) rhs)const shared @safe;
            }

            //const rhs:
            this(ref scope const typeof(this) rhs)@trusted{this(rhs, Evoid.init);}
            this(ref scope const typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            @disable this(ref scope const typeof(this) rhs)immutable @safe;
            static if(is(ControlType == shared)){
                this(ref scope const typeof(this) rhs)shared @trusted{this(rhs, Evoid.init);}
                this(ref scope const typeof(this) rhs)const shared @trusted{this(rhs, Evoid.init);}
            }
            else{
                @disable this(ref scope const typeof(this) rhs)shared @safe;
                @disable this(ref scope const typeof(this) rhs)const shared @safe;
            }

            //immutable rhs:
            this(ref scope immutable typeof(this) rhs)@trusted{this(rhs, Evoid.init);}	//??
            this(ref scope immutable typeof(this) rhs)const @trusted{this(rhs, Evoid.init);}
            this(ref scope immutable typeof(this) rhs)immutable @trusted{this(rhs, Evoid.init);}
            static if(is(ControlType == shared)){
                this(ref scope immutable typeof(this) rhs)shared @trusted{this(rhs, Evoid.init);}
                this(ref scope immutable typeof(this) rhs)const shared @trusted{this(rhs, Evoid.init);}
            }
            else{
                @disable this(ref scope immutable typeof(this) rhs)shared @safe;
                @disable this(ref scope immutable typeof(this) rhs)const shared @safe;
            }

        }
        else static assert(0, "no impl");

        //shared rhs:
        @disable this(ref scope shared typeof(this) rhs)@safe;
        @disable this(ref scope shared typeof(this) rhs)const @safe;
        @disable this(ref scope shared typeof(this) rhs)immutable @safe;
        @disable this(ref scope shared typeof(this) rhs)shared @safe;
        @disable this(ref scope shared typeof(this) rhs)const shared @safe;

        //const shared rhs:
        @disable this(ref scope const shared typeof(this) rhs)@safe;
        @disable this(ref scope const shared typeof(this) rhs)const @safe;
        @disable this(ref scope const shared typeof(this) rhs)immutable @safe;
        @disable this(ref scope const shared typeof(this) rhs)shared @safe;
        @disable this(ref scope const shared typeof(this) rhs)const shared @safe;



        /**
            Releases the ownership of the managed object, if any.

            After the call, this manages no object.

            Examples:
                --------------------
                {
                    RcPtr!long x = RcPtr!long.make(1);

                    assert(x.useCount == 1);
                    x = null;
                    assert(x.useCount == 0);
                    assert(x == null);
                }

                {
                    RcPtr!(shared long) x = RcPtr!(shared long).make(1);

                    assert(x.useCount == 1);
                    x = null;
                    assert(x.useCount == 0);
                    assert(x == null);
                }

                {
                    shared RcPtr!(long).ThreadLocal!false x = RcPtr!(shared long).ThreadLocal!false.make(1);

                    assert(x.useCount == 1);
                    x = null;
                    assert(x.useCount == 0);
                    assert(x == null);
                }
                --------------------
        */
        public void opAssign(MemoryOrder order = MemoryOrder.seq, this This)(typeof(null) nil)scope
        if(isMutable!This){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");

            static if(is(This == shared)){
                static if(isLockFree){
                    import core.atomic : atomicExchange;

                    alias Result = ChangeElementType!(This, ElementType);
                    ()@trusted{
                        Result tmp;
                        tmp._set_element(cast(typeof(this._element))atomicExchange!order(
                            cast(Unqual!(This.ElementReferenceType)*)&this._element,
                            null
                        ));
                    }();
                }
                else{
                    return this.lockPtr!(
                        (ref scope self) => self.opAssign!order(null)
                    )();
                }
            }
            else{
                this._release();
                this._reset();
            }
        }

        /**
            Shares ownership of the object managed by `rhs`.

            If `rhs` manages no object, `this` manages no object too.
            If `rhs` is rvalue then move-assigns a `RcPtr` from `rhs`

            Examples:
                --------------------
                {
                    RcPtr!long px1 = RcPtr!long.make(1);
                    RcPtr!long px2 = RcPtr!long.make(2);

                    assert(px2.useCount == 1);
                    px1 = px2;
                    assert(*px1 == 2);
                    assert(px2.useCount == 2);
                }


                {
                    RcPtr!long px = RcPtr!long.make(1);
                    RcPtr!(const long) pcx = RcPtr!long.make(2);

                    assert(px.useCount == 1);
                    pcx = px;
                    assert(*pcx == 1);
                    assert(pcx.useCount == 2);

                }


                {
                    const RcPtr!long cpx = RcPtr!long.make(1);
                    RcPtr!(const long) pcx = RcPtr!long.make(2);

                    assert(pcx.useCount == 1);
                    pcx = cpx;
                    assert(*pcx == 1);
                    assert(pcx.useCount == 2);

                }

                {
                    RcPtr!(immutable long) pix = RcPtr!(immutable long).make(123);
                    RcPtr!(const long) pcx = RcPtr!long.make(2);

                    assert(pix.useCount == 1);
                    pcx = pix;
                    assert(*pcx == 123);
                    assert(pcx.useCount == 2);

                }
                --------------------
        */
        public void opAssign(MemoryOrder order = MemoryOrder.seq, Rhs, this This)(ref scope Rhs desired)scope
        if(true
            && isRcPtr!Rhs
            && isAssignable!(Rhs, This)
            && !is(Rhs == shared)
        ){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");
            static assert(isValidRcPtr!Rhs, "`Rhs` is invalid `RcPtr`");

            if((()@trusted => cast(const void*)&desired is cast(const void*)&this)())
                return;

            static if(is(This == shared)){

                static if(isLockFree){
                    import core.atomic : atomicExchange;

                    alias Result = ChangeElementType!(This, ElementType);
                    ()@trusted{
                        desired._control.add!(This.weakPtr);

                        Result tmp;
                        GetElementReferenceType!This source = desired._element;    //interface/class cast

                        tmp._set_element(cast(typeof(this._element))atomicExchange!order(
                            cast(Unqual!(This.ElementReferenceType)*)&this._element,
                            cast(Unqual!(This.ElementReferenceType))source
                        ));
                    }();
                }
                else{
                    this.lockPtr!(
                        (ref scope self, ref scope Rhs x) => self.opAssign!order(x)
                    )(desired);
                }
            }
            else{
                this._release();
                ()@trusted{
                    auto control = desired._control;
                    this._set_element(desired._element);

                    if(control !is null)
                        control.add!weakPtr;

                }();
            }
        }

        ///ditto
        public void opAssign(MemoryOrder order = MemoryOrder.seq, Rhs, this This)(scope Rhs desired)scope
        if(true
            && isRcPtr!Rhs
            && isAssignable!(Rhs, This)
            && !is(Rhs == shared)
        ){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");
            static assert(isValidRcPtr!Rhs, "`Rhs` is invalid `RcPtr`");

            static if(is(This == shared)){
                static if(isLockFree){
                    import core.atomic : atomicExchange;

                    alias Result = ChangeElementType!(This, ElementType);
                    ()@trusted{
                        Result tmp;
                        GetElementReferenceType!This source = desired._element;    //interface/class cast

                        tmp._set_element(cast(typeof(this._element))atomicExchange!order(
                            cast(Unqual!(This.ElementReferenceType)*)&this._element,
                            cast(Unqual!(This.ElementReferenceType))source
                        ));

                        desired._const_reset();
                    }();
                }
                else{
                    return this.lockPtr!(
                        (ref scope self, Rhs x) => self.opAssign!order(x.move)
                    )(desired.move);
                }
            }
            else{

                this._release();

                ()@trusted{
                    this._set_element(desired._element);
                    desired._const_reset();
                }();

            }
        }



        /**
            Constructs an object of type `ElementType` and wraps it in a `RcPtr` using args as the parameter list for the constructor of `ElementType`.

            The object is constructed as if by the expression `emplace!ElementType(_payload, forward!args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
            The storage is typically larger than `ElementType.sizeof` in order to use one allocation for both the control block and the `ElementType` object.

            Examples:
                --------------------
                {
                    RcPtr!long a = RcPtr!long.make();
                    assert(a.get == 0);

                    RcPtr!(const long) b = RcPtr!long.make(2);
                    assert(b.get == 2);
                }

                {
                    static struct Struct{
                        int i = 7;

                        this(int i)pure nothrow @safe @nogc{
                            this.i = i;
                        }
                    }

                    RcPtr!Struct s1 = RcPtr!Struct.make();
                    assert(s1.get.i == 7);

                    RcPtr!Struct s2 = RcPtr!Struct.make(123);
                    assert(s2.get.i == 123);
                }

                {
                    static interface Interface{
                    }
                    static class Class : Interface{
                        int i;

                        this(int i)pure nothrow @safe @nogc{
                            this.i = i;
                        }
                    }

                    RcPtr!Interface x = RcPtr!Class.make(3);
                    //assert(x.dynTo!Class.get.i == 3);
                }
                --------------------
        */
        static if(!weakPtr)
        public static RcPtr!(ElementType, .DestructorType!(.DestructorType!ElementType, DestructorType, DestructorAllocatorType!AllocatorType), ControlType)
        make(AllocatorType = DefaultAllocator, bool supportGC = platformSupportGC, Args...)(auto ref Args args)
        if(stateSize!AllocatorType == 0 && !isDynamicArray!ElementType){
            static assert(!weakPtr);

            auto m = typeof(return).MakeEmplace!(AllocatorType, supportGC).make(forward!(args));

            return (m is null)
                ? typeof(return).init
                : typeof(return)(m.get, Evoid.init);
        }


        /**
            Constructs an object of array type `ElementType` including its array elements and wraps it in a `RcPtr`.

            Parameters:
                n = Array length

                args = parameters for constructor for each array element.

            The array elements are constructed as if by the expression `emplace!ElementType(_payload, args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
            The storage is typically larger than `ElementType.sizeof * n` in order to use one allocation for both the control block and the each array element.

            Examples:
                --------------------
                auto arr = RcPtr!(long[]).make(6, -1);
                assert(arr.length == 6);
                assert(arr.get.length == 6);

                import std.algorithm : all;
                assert(arr.get.all!(x => x == -1));

                for(long i = 0; i < 6; ++i)
                    arr.get[i] = i;

                assert(arr.get == [0, 1, 2, 3, 4, 5]);
                --------------------
        */
        static if(!weakPtr)
        public static RcPtr!(ElementType, .DestructorType!(.DestructorType!ElementType, DestructorType, DestructorAllocatorType!AllocatorType), ControlType)
        make(AllocatorType = DefaultAllocator, bool supportGC = platformSupportGC, Args...)(const size_t n, auto ref Args args)
        if(stateSize!AllocatorType == 0 && isDynamicArray!ElementType){
            static assert(!weakPtr);

            auto m = typeof(return).MakeDynamicArray!(AllocatorType, supportGC).make(n, forward!(args));

            return (m is null)
                ? typeof(return).init
                : typeof(return)(m.get, Evoid.init);
        }



        /**
            Constructs an object of type `ElementType` and wraps it in a `RcPtr` using args as the parameter list for the constructor of `ElementType`.

            The object is constructed as if by the expression `emplace!ElementType(_payload, forward!args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
            The storage is typically larger than `ElementType.sizeof` in order to use one allocation for both the control block and the `ElementType` object.

            Examples:
                --------------------
                auto a = allocatorObject(Mallocator.instance);
                {
                    auto a = RcPtr!long.alloc(a);
                    assert(a.get == 0);

                    auto b = RcPtr!(const long).alloc(a, 2);
                    assert(b.get == 2);
                }

                {
                    static struct Struct{
                        int i = 7;

                        this(int i)pure nothrow @safe @nogc{
                            this.i = i;
                        }
                    }

                    auto s1 = RcPtr!Struct.alloc(a);
                    assert(s1.get.i == 7);

                    auto s2 = RcPtr!Struct.alloc(a, 123);
                    assert(s2.get.i == 123);
                }

                {
                    static interface Interface{
                    }
                    static class Class : Interface{
                        int i;

                        this(int i)pure nothrow @safe @nogc{
                            this.i = i;
                        }
                    }

                    RcPtr!Interface x = RcPtr!Class.alloc(a, 3);
                    //assert(x.dynTo!Class.get.i == 3);
                }
                --------------------
        */
        static if(!weakPtr)
        public static RcPtr!(ElementType, .DestructorType!(.DestructorType!ElementType, DestructorType, DestructorAllocatorType!AllocatorType), ControlType)
        alloc(bool supportGC = platformSupportGC, AllocatorType, Args...)(AllocatorType a, auto ref Args args)
        if(stateSize!AllocatorType >= 0 && !isDynamicArray!ElementType){
            static assert(!weakPtr);

            auto m = typeof(return).MakeEmplace!(AllocatorType, supportGC).make(forward!(a, args));

            return (m is null)
                ? typeof(return).init
                : typeof(return)(m.get, Evoid.init);
        }



        /**
            Constructs an object of array type `ElementType` including its array elements and wraps it in a `RcPtr`.

            Parameters:
                n = Array length

                args = parameters for constructor for each array element.

            The array elements are constructed as if by the expression `emplace!ElementType(_payload, args)`, where _payload is an internal pointer to storage suitable to hold an object of type `ElementType`.
            The storage is typically larger than `ElementType.sizeof * n` in order to use one allocation for both the control block and the each array element.

            Examples:
                --------------------
                auto a = allocatorObject(Mallocator.instance);
                auto arr = RcPtr!(long[], DestructorType!(typeof(a))).alloc(a, 6, -1);
                assert(arr.length == 6);
                assert(arr.get.length == 6);

                import std.algorithm : all;
                assert(arr.get.all!(x => x == -1));

                for(long i = 0; i < 6; ++i)
                    arr.get[i] = i;

                assert(arr.get == [0, 1, 2, 3, 4, 5]);
                --------------------
        */
        static if(!weakPtr)
        public static RcPtr!(ElementType, .DestructorType!(.DestructorType!ElementType, DestructorType, DestructorAllocatorType!AllocatorType), ControlType)
        alloc(bool supportGC = platformSupportGC, AllocatorType, Args...)(AllocatorType a, const size_t n, auto ref Args args)
        if(stateSize!AllocatorType >= 0 && isDynamicArray!ElementType){
            static assert(!weakPtr);

            auto m = typeof(return).MakeDynamicArray!(AllocatorType, supportGC).make(forward!(a, n, args));

            return (m is null)
                ? typeof(return).init
                : typeof(return)(m.get, Evoid.init);
        }



        /**
            Returns the number of different `RcPtr` instances

            Returns the number of different `RcPtr` instances (`this` included) managing the current object or `0` if there is no managed object.

            Examples:
                --------------------
                RcPtr!long x = null;

                assert(x.useCount == 0);

                x = RcPtr!long.make(123);
                assert(x.useCount == 1);

                auto y = x;
                assert(x.useCount == 2);

                auto w1 = x.weak;    //weak ptr
                assert(x.useCount == 2);

                RcPtr!long.WeakType w2 = x;   //weak ptr
                assert(x.useCount == 2);

                y = null;
                assert(x.useCount == 1);

                x = null;
                assert(x.useCount == 0);
                assert(w1.useCount == 0);
                --------------------
        */
        public @property ControlType.Shared useCount(this This)()const scope nothrow @trusted @nogc{
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");

            static if(is(This == shared)){
                static assert(is(ControlType == shared));

                return this.lockPtr!(
                    (ref scope return self) => self.useCount()
                )();
            }
            else{
                return (this._element is null)
                    ? 0
                    : this._control.count!false + 1;
            }

        }


        /**
            Returns the number of different `RcPtr.WeakType` instances

            Returns the number of different `RcPtr.WeakType` instances (`this` included) managing the current object or `0` if there is no managed object.

            Examples:
                --------------------
                RcPtr!long x = null;
                assert(x.useCount == 0);
                assert(x.weakCount == 0);

                x = RcPtr!long.make(123);
                assert(x.useCount == 1);
                assert(x.weakCount == 0);

                auto w = x.weak();
                assert(x.useCount == 1);
                assert(x.weakCount == 1);
                --------------------
        */
        public @property ControlType.Weak weakCount(this This)()const scope nothrow @safe @nogc{
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");

            static if(is(This == shared)){
                static assert(is(ControlType == shared));

                return this.lockSharedPtr!(
                    (ref scope return self) => self.weakCount()
                )();
            }
            else{
                return (this._element is null)
                    ? 0
                    : this._control.count!true;
            }

        }



        /**
            Swap `this` with `rhs`

            Examples:
                --------------------
                {
                    RcPtr!long a = RcPtr!long.make(1);
                    RcPtr!long b = RcPtr!long.make(2);
                    a.proxySwap(b);
                    assert(*a == 2);
                    assert(*b == 1);
                    import std.algorithm : swap;
                    swap(a, b);
                    assert(*a == 1);
                    assert(*b == 2);
                    assert(a.useCount == 1);
                    assert(b.useCount == 1);
                }
                --------------------
        */
        public void proxySwap(ref scope typeof(this) rhs)scope @trusted pure nothrow @nogc{
            auto element = this._element;
            this._set_element(rhs._element);
            rhs._set_element(element);
        }



        /**
            Returns the non `shared` `RcPtr` pointer pointed-to by `shared` `this`.

            Examples:
                --------------------
                shared RcPtr!(long).ThreadLocal!false x = RcPtr!(shared long).ThreadLocal!false.make(123);

                {
                    RcPtr!(shared long) y = x.load();
                    assert(y.useCount == 2);

                    assert(y.get == 123);
                }
                --------------------
        */
        public ChangeElementType!(This, CopyTypeQualifiers!(This, ElementType))
        load(MemoryOrder order = MemoryOrder.seq, this This)()scope return{
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");

            static if(is(This == shared)){
                static assert(is(ControlType == shared));

                return this.lockPtr!(
                    (ref scope return self) => self.load!order()
                )();
            }
            else{
                return typeof(return)(this);
            }
        }



        /**
            Stores the non `shared` `RcPtr` parameter `ptr` to `this`.

            If `this` is shared then operation is atomic or guarded by mutex.

            Template parameter `order` has type `core.atomic.MemoryOrder`.

            Examples:
                --------------------
                //null store:
                {
                    shared x = RcPtr!(shared long).make(123);
                    assert(x.load.get == 123);

                    x.store(null);
                    assert(x.useCount == 0);
                    assert(x.load == null);
                }

                //rvalue store:
                {
                    shared x = RcPtr!(shared long).make(123);
                    assert(x.load.get == 123);

                    x.store(RcPtr!(shared long).make(42));
                    assert(x.load.get == 42);
                }

                //lvalue store:
                {
                    shared x = RcPtr!(shared long).make(123);
                    auto y = RcPtr!(shared long).make(42);

                    assert(x.load.get == 123);
                    assert(y.load.get == 42);

                    x.store(y);
                    assert(x.load.get == 42);
                    assert(x.useCount == 2);
                }
                --------------------
        */
        alias store = opAssign;



        /**
            Stores the non `shared` `RcPtr` pointer ptr in the `shared(RcPtr)` pointed to by `this` and returns the value formerly pointed-to by this, atomically or with mutex.

            Examples:
                --------------------
                //lvalue exchange
                {
                    shared x = RcPtr!(shared long).make(123);
                    auto y = RcPtr!(shared long).make(42);

                    auto z = x.exchange(y);

                    assert(x.load.get == 42);
                    assert(y.get == 42);
                    assert(z.get == 123);
                }

                //rvalue exchange
                {
                    shared x = RcPtr!(shared long).make(123);
                    auto y = RcPtr!(shared long).make(42);

                    auto z = x.exchange(y.move);

                    assert(x.load.get == 42);
                    assert(y == null);
                    assert(z.get == 123);
                }

                //null exchange (same as move)
                {
                    shared x = RcPtr!(shared long).make(123);

                    auto z = x.exchange(null);

                    assert(x.load == null);
                    assert(z.get == 123);
                }

                //swap:
                {
                    shared x = RcPtr!(shared long).make(123);
                    auto y = RcPtr!(shared long).make(42);

                    //opAssign is same as store
                    y = x.exchange(y.move);

                    assert(x.load.get == 42);
                    assert(y.get == 123);
                }
                --------------------
        */
        public RcPtr exchange(MemoryOrder order = MemoryOrder.seq, this This)(typeof(null))scope
        if(isMutable!This){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");

            static if(is(This == shared)){
                static if(isLockFree){
                    import core.atomic : atomicExchange;

                    return()@trusted{
                        alias Result = ChangeElementType!(This, ElementType);
                        Result result;
                        result._set_element(cast(typeof(this._element))atomicExchange!order(
                            cast(Unqual!(This.ElementReferenceType)*)&this._element,
                            null
                        ));

                        return result.move;
                    }();
                }
                else{
                    return this.lockPtr!(
                        (ref scope self) => self.exchange!order(null)
                    )();
                }
            }
            else{
                return this.move;
            }
        }

        /// ditto
        public RcPtr exchange(MemoryOrder order = MemoryOrder.seq, Rhs, this This)(scope Rhs rhs)scope
        if(true
            && isRcPtr!Rhs
            && isAssignable!(Rhs, This)
            && !is(Rhs == shared)
        ){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");
            static assert(isValidRcPtr!Rhs, "`Rhs` is invalid `RcPtr`");

            static if(is(This == shared)){

                static if(isLockFree){
                    import core.atomic : atomicExchange;

                    return()@trusted{
                        alias Result = ChangeElementType!(This, ElementType);
                        Result result;
                        GetElementReferenceType!This source = rhs._element;    //interface/class cast

                        result._set_element(cast(typeof(this._element))atomicExchange!order(
                            cast(Unqual!(This.ElementReferenceType)*)&this._element,
                            cast(Unqual!(This.ElementReferenceType))source
                        ));
                        rhs._const_reset();

                        return result.move;
                    }();
                }
                else{
                    return this.lockPtr!(
                        (ref scope self, Rhs x) => self.exchange!order(x.move)
                    )(rhs.move);
                }
            }
            else{
                auto result = this.move;

                return()@trusted{
                    this = rhs.move;
                    return result.move;
                }();
            }
        }


        /**
            Compares the `RcPtr` pointers pointed-to by `this` and `expected`.

            If they are equivalent (store the same pointer value, and either share ownership of the same object or are both empty), assigns `desired` into `this` using the memory ordering constraints specified by `success` and returns `true`.
            If they are not equivalent, assigns `this` into `expected` using the memory ordering constraints specified by `failure` and returns `false`.

            More info in c++ std::atomic<std::shared_ptr>.


            Examples:
                --------------------
                static foreach(enum bool weak; [true, false]){
                    //fail
                    {
                        RcPtr!long a = RcPtr!long.make(123);
                        RcPtr!long b = RcPtr!long.make(42);
                        RcPtr!long c = RcPtr!long.make(666);

                        static if(weak)a.compareExchangeWeak(b, c);
                        else a.compareExchangeStrong(b, c);

                        assert(*a == 123);
                        assert(*b == 123);
                        assert(*c == 666);

                    }

                    //success
                    {
                        RcPtr!long a = RcPtr!long.make(123);
                        RcPtr!long b = a;
                        RcPtr!long c = RcPtr!long.make(666);

                        static if(weak)a.compareExchangeWeak(b, c);
                        else a.compareExchangeStrong(b, c);

                        assert(*a == 666);
                        assert(*b == 123);
                        assert(*c == 666);
                    }

                    //shared fail
                    {
                        shared RcPtr!(shared long) a = RcPtr!(shared long).make(123);
                        RcPtr!(shared long) b = RcPtr!(shared long).make(42);
                        RcPtr!(shared long) c = RcPtr!(shared long).make(666);

                        static if(weak)a.compareExchangeWeak(b, c);
                        else a.compareExchangeStrong(b, c);

                        auto tmp = a.exchange(null);
                        assert(*tmp == 123);
                        assert(*b == 123);
                        assert(*c == 666);
                    }

                    //shared success
                    {
                        RcPtr!(shared long) b = RcPtr!(shared long).make(123);
                        shared RcPtr!(shared long) a = b;
                        RcPtr!(shared long) c = RcPtr!(shared long).make(666);

                        static if(weak)a.compareExchangeWeak(b, c);
                        else a.compareExchangeStrong(b, c);

                        auto tmp = a.exchange(null);
                        assert(*tmp == 666);
                        assert(*b == 123);
                        assert(*c == 666);
                    }
                }
                --------------------
        */
        public bool compareExchangeStrong
            (MemoryOrder success = MemoryOrder.seq, MemoryOrder failure = success, E, D, this This)
            (ref scope E expected, scope D desired)scope
        if(true
            && isRcPtr!E && !is(E == shared)
            && isRcPtr!D && !is(D == shared)
            && isAssignable!(D, This)
            && isAssignable!(This, E)
            && (This.weakPtr == D.weakPtr)
            && (This.weakPtr == E.weakPtr)
        ){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");
            static assert(isValidRcPtr!E, "`E expected` is invalid `RcPtr`");
            static assert(isValidRcPtr!D, "`D desired` is invalid `RcPtr`");

            return this.compareExchangeImpl!(false, success, failure)(expected, desired.move);
        }



        /**
            Same as `compareExchangeStrong` but may fail spuriously.

            More info in c++ `std::atomic<std::shared_ptr>`.
        */
        public bool compareExchangeWeak
            (MemoryOrder success = MemoryOrder.seq, MemoryOrder failure = success, E, D, this This)
            (ref scope E expected, scope D desired)scope
        if(true
            && isRcPtr!E && !is(E == shared)
            && isRcPtr!D && !is(D == shared)
            && isAssignable!(D, This)
            && isAssignable!(This, E)
            && (This.weakPtr == D.weakPtr)
            && (This.weakPtr == E.weakPtr)
        ){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");
            static assert(isValidRcPtr!E, "`E expected` is invalid `RcPtr`");
            static assert(isValidRcPtr!D, "`D desired` is invalid `RcPtr`");

            return this.compareExchangeImpl!(true, success, failure)(expected, desired.move);
        }


        private bool compareExchangeImpl
            (bool weak, MemoryOrder success, MemoryOrder failure, E, D, this This)
            (ref scope E expected, scope D desired)scope @trusted
        if(true
            && isRcPtr!E && !is(E == shared)
            && isRcPtr!D && !is(D == shared)
            && isAssignable!(D, This)
            && isAssignable!(This, E)
            && (This.weakPtr == D.weakPtr)
            && (This.weakPtr == E.weakPtr)
        ){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");
            static assert(isValidRcPtr!E, "`E expected` is invalid `RcPtr`");
            static assert(isValidRcPtr!D, "`D desired` is invalid `RcPtr`");

            static if(is(This == shared)){
                static if(isLockFree){
                    import core.atomic : cas, casWeak;
                    static if(weak)
                        alias casImpl = casWeak;
                    else
                        alias casImpl = cas;


                    return ()@trusted{
                        GetElementReferenceType!This source_desired = desired._element;     //interface/class cast
                        GetElementReferenceType!This source_expected = expected._element;   //interface/class cast

                        const bool store_occurred = casImpl!(success, failure)(
                            cast(Unqual!(This.ElementReferenceType)*)&this._element,
                            cast(Unqual!(This.ElementReferenceType)*)&source_expected,
                            cast(Unqual!(This.ElementReferenceType))source_desired
                        );

                        if(store_occurred){
                            desired._const_reset();
                            if(expected._element !is null)
                                expected._control.release!(This.weakPtr);
                        }
                        else{
                            expected = null;
                            expected._set_element(source_expected);
                        }

                        return store_occurred;
                    }();
                }
                else{
                    static assert(!isLockFree);
                    shared mutex = getMutex(this);

                    mutex.lock();

                    alias Self = ChangeElementType!(
                        This, //CopyConstness!(This, Unqual!This),
                        CopyTypeQualifiers!(This, ElementType)
                    );

                    static assert(!is(Self == shared));

                    Self* self = cast(Self*)&this;

                    if(*self == expected){
                        auto tmp = self.move;   //destructor is called after  mutex.unlock();
                        *self = desired.move;

                        mutex.unlock();
                        return true;
                    }

                    auto tmp = expected.move;   //destructor is called after  mutex.unlock();
                    expected = *self;

                    mutex.unlock();
                    return false;
                }
            }
            else{
                if(this == expected){
                    this = desired.move;
                    return true;
                }
                expected = this;

                return false;
            }
        }



        /**
            Creates a new non weak `RcPtr` that shares ownership of the managed object (must be `RcPtr.WeakType`).

            If there is no managed object, i.e. this is empty or this is `expired`, then the returned `RcPtr` is empty.
            Method exists only if `RcPtr` is `weakPtr`

            Examples:
                --------------------
                {
                    RcPtr!long x = RcPtr!long.make(123);

                    auto w = x.weak;    //weak ptr

                    RcPtr!long y = w.lock;

                    assert(x == y);
                    assert(x.useCount == 2);
                    assert(y.get == 123);
                }

                {
                    RcPtr!long x = RcPtr!long.make(123);

                    auto w = x.weak;    //weak ptr

                    assert(w.expired == false);

                    x = RcPtr!long.make(321);

                    assert(w.expired == true);

                    RcPtr!long y = w.lock;

                    assert(y == null);
                }
                --------------------
        */
        static if(weakPtr)
        public CopyConstness!(This, SharedType) lock(this This)()scope @trusted
        if(!is(This == shared)){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");

            static assert(weakLock!(This, typeof(return)));

            return typeof(return)(this);
        }



        /**
            Equivalent to `useCount() == 0` (must be `RcPtr.WeakType`).

            Method exists only if `RcPtr` is `weakPtr`

            Examples:
                --------------------
                {
                    RcPtr!long x = RcPtr!long.make(123);

                    auto wx = x.weak;   //weak pointer

                    assert(wx.expired == false);

                    x = null;

                    assert(wx.expired == true);
                }
                --------------------
        */
        static if(weakPtr)
        public @property bool expired(this This)()scope const{
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");

            return (this.useCount == 0);
        }


        static if(!weakPtr){
            /**
                Operator *, same as method 'get'.

                Examples:
                    --------------------
                    RcPtr!long x = RcPtr!long.make(123);
                    assert(*x == 123);
                    (*x = 321);
                    assert(*x == 321);
                    const y = x;
                    assert(*y == 321);
                    assert(*x == 321);
                    static assert(is(typeof(*y) == const long));
                    --------------------
            */
            public template opUnary(string op : "*")
            if(op == "*"){  //doc
                alias opUnary = get;
            }



            /**
                Get reference to managed object of `ElementType` or value if `ElementType` is reference type (class or interface) or dynamic array.

                Examples:
                    --------------------
                    RcPtr!long x = RcPtr!long.make(123);
                    assert(x.get == 123);
                    x.get = 321;
                    assert(x.get == 321);
                    const y = x;
                    assert(y.get == 321);
                    assert(x.get == 321);
                    static assert(is(typeof(y.get) == const long));
                    --------------------
            */
            static if(referenceElementType)
                public @property inout(ElementType) get()inout scope return pure nothrow @system @nogc{
                    return this._element;
                }
            else static if(is(Unqual!ElementType == void))
                /// ditto
                public @property inout(ElementType) get()inout scope pure nothrow @system @nogc{
                }
            else
                /// ditto
                public @property ref inout(ElementType) get()inout scope return pure nothrow @system @nogc{
                    return *cast(inout ElementType*)this._element;
                }




            /**
                Get pointer to managed object of `ElementType` or reference if `ElementType` is reference type (class or interface) or dynamic array

                Examples:
                    --------------------
                    RcPtr!long x = RcPtr!long.make(123);
                    assert(*x.element == 123);
                    x.get = 321;
                    assert(*x.element == 321);
                    const y = x;
                    assert(*y.element == 321);
                    assert(*x.element == 321);
                    static assert(is(typeof(y.ptr) == const(long)*));
                    --------------------
            */
            public @property ElementReferenceTypeImpl!(inout ElementType) element()
            inout scope return pure nothrow @system @nogc{
                return this._element;
            }

        }



        /**
            Returns length of dynamic array (isDynamicArray!ElementType == true).

            Examples:
                --------------------
                auto x = RcPtr!(int[]).make(10, -1);
                assert(x.length == 10);
                assert(x.get.length == 10);

                import std.algorithm : all;
                assert(x.get.all!(i => i == -1));
                --------------------
        */
        static if(isDynamicArray!ElementType)
        public @property size_t length()const scope pure nothrow @safe @nogc{
            return this._element.length;
        }


        /**
            Returns weak pointer (must have weak counter).

            Examples:
                --------------------
                RcPtr!long x = RcPtr!long.make(123);
                assert(x.useCount == 1);
                auto wx = x.weak;   //weak pointer
                assert(wx.expired == false);
                assert(wx.lock.get == 123);
                assert(wx.useCount == 1);
                x = null;
                assert(wx.expired == true);
                assert(wx.useCount == 0);
                --------------------
        */
        static if(hasWeakCounter)
        public CopyTypeQualifiers!(This, WeakType) weak(this This)()scope @safe
        if(!is(This == shared)){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");

            return typeof(return)(this);
        }



        /**
            Checks if `this` stores a non-null pointer, i.e. whether `this != null`.

            Examples:
                --------------------
                RcPtr!long x = RcPtr!long.make(123);
                assert(cast(bool)x);    //explicit cast
                assert(x);              //implicit cast
                x = null;
                assert(!cast(bool)x);   //explicit cast
                assert(!x);             //implicit cast
                --------------------
        */
        public bool opCast(To : bool)()const scope pure nothrow @safe @nogc
        if(is(To : bool)){ //docs
            return (this != null);
        }


        /**
            Cast `this` to different type `To` when `isRcPtr!To`.

            Examples:
                --------------------
                RcPtr!long x = RcPtr!long.make(123);
                auto y = cast(RcPtr!(const long))x;
                auto z = cast(const RcPtr!long)x;
                auto u = cast(const RcPtr!(const long))x;
                assert(x.useCount == 4);
                --------------------
        */
        public To opCast(To, this This)()scope
        if(isRcPtr!To && !is(This == shared)){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");
            static assert(isValidRcPtr!To, "`To` is invalid `RcPtr`");

            return To(this);
        }


        /**
            Operator == and != .
            Compare pointers.

            Examples:
                --------------------
                {
                    RcPtr!long x = RcPtr!long.make(0);
                    assert(x != null);
                    x = null;
                    assert(x == null);
                }

                {
                    RcPtr!long x = RcPtr!long.make(123);
                    RcPtr!long y = RcPtr!long.make(123);
                    assert(x == x);
                    assert(y == y);
                    assert(x != y);
                }

                {
                    RcPtr!long x;
                    RcPtr!(const long) y;
                    assert(x == x);
                    assert(y == y);
                    assert(x == y);
                }

                {
                    RcPtr!long x = RcPtr!long.make(123);
                    RcPtr!long y = RcPtr!long.make(123);
                    assert(x == x.element);
                    assert(y.element == y);
                    assert(x != y.element);
                }
                --------------------
        */
        public bool opEquals(typeof(null) nil)const @safe scope pure nothrow @nogc{
            static if(isDynamicArray!ElementType)
                return (this._element.length == 0);
            else
                return (this._element is null);
        }

        /// ditto
        public bool opEquals(Rhs)(auto ref scope const Rhs rhs)const @safe scope pure nothrow @nogc
        if(isRcPtr!Rhs && !is(Rhs == shared)){
            static assert(isValidRcPtr!Rhs, "`Rhs` is invalid `RcPtr`");

            return this.opEquals(rhs._element);
        }

        /// ditto
        public bool opEquals(Elm)(scope const Elm elm)const @safe scope pure nothrow @nogc
        if(is(Elm : GetElementReferenceType!(typeof(this)))){
            static if(isDynamicArray!ElementType){
                static assert(isDynamicArray!Elm);

                if(this._element.length != elm.length)
                    return false;

                if(this._element.ptr is elm.ptr)
                    return true;

                return (this._element.length == 0);
            }
            else{
                return (this._element is elm);
            }
        }



        /**
            Operators <, <=, >, >= for `RcPtr`.

            Compare address of payload.

            Examples:
                --------------------
                {
                    const a = RcPtr!long.make(42);
                    const b = RcPtr!long.make(123);
                    const n = RcPtr!long.init;

                    assert(a <= a);
                    assert(a >= a);

                    assert((a < b) == !(a >= b));
                    assert((a > b) == !(a <= b));

                    assert(a > n);
                    assert(a > null);

                    assert(n < a);
                    assert(null < a);
                }

                {
                    const a = RcPtr!long.make(42);
                    const b = RcPtr!long.make(123);

                    assert(a <= a.element);
                    assert(a.element >= a);

                    assert((a < b.element) == !(a.element >= b));
                    assert((a > b.element) == !(a.element <= b));
                }
                --------------------
        */
        public sizediff_t opCmp(typeof(null) nil)const @trusted scope pure nothrow @nogc{
            static if(isDynamicArray!ElementType){
                return this._element.length;
            }
            else{
                return (cast(const void*)this._element) - (cast(const void*)null);
            }

        }

        /// ditto
        public sizediff_t opCmp(Elm)(scope const Elm elm)const @trusted scope pure nothrow @nogc
        if(is(Elm : GetElementReferenceType!(typeof(this)))){
            static if(isDynamicArray!ElementType){
                const void* lhs = cast(const void*)(this._element.ptr + this._element.length);
                const void* rhs = cast(const void*)(elm.ptr + elm.length);

                return lhs - rhs;
            }
            else{
                return (cast(const void*)this._element) - (cast(const void*)elm);
            }
        }

        /// ditto
        public sizediff_t opCmp(Rhs)(auto ref scope const Rhs rhs)const @trusted scope pure nothrow @nogc
        if(isRcPtr!Rhs && !is(Rhs == shared)){
            static assert(isValidRcPtr!Rhs, "`Rhs` is invalid `RcPtr`");

            return this.opCmp(rhs._element);
        }



        /**
            Generate hash

            Return:
                Address of payload as `size_t`

            Examples:
                --------------------
                {
                    RcPtr!long x = RcPtr!long.make(123);
                    RcPtr!long y = RcPtr!long.make(123);
                    assert(x.toHash == x.toHash);
                    assert(y.toHash == y.toHash);
                    assert(x.toHash != y.toHash);
                    RcPtr!(const long) z = x;
                    assert(x.toHash == z.toHash);
                }
                {
                    RcPtr!long x;
                    RcPtr!(const long) y;
                    assert(x.toHash == x.toHash);
                    assert(y.toHash == y.toHash);
                    assert(x.toHash == y.toHash);
                }
                --------------------
        */
        public @property size_t toHash()@trusted scope const pure nothrow @nogc {
            static if(isDynamicArray!ElementType)
                return cast(size_t)cast(void*)(this._element.ptr + this._element.length);
            else
                return cast(size_t)cast(void*)this._element;
        }



        /**
            Move `RcPtr`
        */
        public RcPtr move()()scope{
            import core.lifetime : move_impl = move;

            return move_impl(this);
        }

        private ElementReferenceType _element;


        package ControlType* _control(this This)()pure nothrow @trusted @nogc
        in(this._element !is null){
            static assert(isValidRcPtr!This, "`This` is invalid `RcPtr`");

            static if(isDynamicArray!ElementType){
                return cast(ControlType*)((cast(void*)this._element.ptr) - ControlType.sizeof);
            }
            else static if(is(ElementType == interface)){
                static assert(__traits(getLinkage, ElementType) == "D");
                return cast(ControlType*)((cast(void*)cast(Object)cast(Unqual!ElementType)this._element) - ControlType.sizeof);
            }
            else{
                return cast(ControlType*)((cast(void*)this._element) - ControlType.sizeof);
            }
        }

        private void _set_element(ElementReferenceType e)pure nothrow @trusted @nogc{
            static if(isMutable!ElementReferenceType)
                this._element = e;
            else
                (*cast(Unqual!ElementReferenceType*)&this._element) = cast(Unqual!ElementReferenceType)e;
        }

        private void _const_set_element(ElementReferenceType e)const pure nothrow @trusted @nogc{
            auto self = cast(Unqual!(typeof(this))*)&this;

            static if(isMutable!ElementReferenceType)
                self._element = e;
            else
                (*cast(Unqual!ElementReferenceType*)&self._element) = cast(Unqual!ElementReferenceType)e;
        }

        private void _release()scope /*pure nothrow @safe @nogc*/ {
            if(false){
                DestructorType dt;
                dt(null);
            }

            import std.traits : hasIndirections;
            import core.memory : GC;

            if(this._element is null)
                return;

            this._control.release!weakPtr;
        }

        private void _reset()scope pure nothrow @trusted @nogc{
            this._set_element(null);
        }

        package void _const_reset()scope const pure nothrow @trusted @nogc{
            auto self = cast(Unqual!(typeof(this))*)&this;

            self._reset();
        }

        private alias MakeEmplace(AllocatorType, bool supportGC) = .MakeEmplace!(
            _Type,
            _DestructorType,
            _ControlType,
            AllocatorType,
            supportGC
        );

        private alias MakeDynamicArray(AllocatorType, bool supportGC) = .MakeDynamicArray!(
            _Type,
            _DestructorType,
            _ControlType,
            AllocatorType,
            supportGC
        );
    }

}

/// ditto
public template RcPtr(
    _Type,
    _ControlType,
    _DestructorType = DestructorType!_Type
)
if(isControlBlock!_ControlType && isDestructorType!_DestructorType){
    alias RcPtr = .RcPtr!(_Type, _DestructorType, _ControlType, false);
}

///
pure nothrow @nogc unittest{

    static class Foo{
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    static class Bar : Foo{
        double d;

        this(int i, double d)pure nothrow @safe @nogc{
            super(i);
            this.d = d;
        }
    }

    //implicit qualifier cast
    {
        RcPtr!(const Foo) foo =  RcPtr!Foo.make(42);
        assert(foo.get.i == 42);
        assert(foo.useCount == 1);

        const RcPtr!Foo foo2 = foo;
        assert(foo2.get.i == 42);
        assert(foo.useCount == 2);

    }

    //polymorphic classes:
    {
        RcPtr!Foo foo = RcPtr!Bar.make(42, 3.14);
        assert(foo != null);
        assert(foo.useCount == 1);
        assert(foo.get.i == 42);

        //dynamic cast:
        {
            RcPtr!Bar bar = dynCast!Bar(foo);
            assert(foo.useCount == 2);

            assert(bar.get.i == 42);
            assert(bar.get.d == 3.14);
        }

    }

    //weak references:
    {
        auto x = RcPtr!double.make(3.14);
        assert(x.useCount == 1);
        assert(x.weakCount == 0);

        auto w = x.weak();  //weak pointer
        assert(x.useCount == 1);
        assert(x.weakCount == 1);
        assert(*w.lock == 3.14);

        RcPtr!double.WeakType w2 = x;
        assert(x.useCount == 1);
        assert(x.weakCount == 2);

        assert(w2.expired == false);
        x = null;
        assert(w2.expired == true);
    }

    //dynamic array
    {
        import std.algorithm : all;

        {
            auto arr = RcPtr!(long[]).make(10, -1);

            assert(arr.length == 10);
            assert(arr.get.all!(x => x == -1));
        }

        {
            auto arr = RcPtr!(long[]).make(8);
            assert(arr.length == 8);
            assert(arr.get.all!(x => x == long.init));
        }
    }

    //static array
    {
        import std.algorithm : all;

        {
            auto arr = RcPtr!(long[4]).make(-1);
            assert(arr.get[].all!(x => x == -1));

        }

        {
            long[4] tmp = [0, 1, 2, 3];
            auto arr = RcPtr!(long[4]).make(tmp);
            assert(arr.get[] == tmp[]);
        }
    }

}

///
pure nothrow @safe @nogc unittest{
    //make RcPtr object
    static struct Foo{
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    {
        auto foo = RcPtr!Foo.make(42);
        auto foo2 = RcPtr!Foo.make!Mallocator(42);  //explicit stateless allocator
    }

    {
        auto arr = RcPtr!(long[]).make(10); //dynamic array with length 10
        assert(arr.length == 10);
    }
}

///
nothrow unittest{
    //alloc RcPtr object
    import std.experimental.allocator : make, dispose, allocatorObject;

    auto allocator = allocatorObject(Mallocator.instance);

    {
        auto x = RcPtr!(long, void function(Evoid* )nothrow).alloc(allocator, 42);
    }

    {
        auto arr = RcPtr!(long[]).alloc(allocator, 10); //dynamic array with length 10
        assert(arr.length == 10);
    }

}


//make:
pure nothrow @safe @nogc unittest{
    import std.experimental.allocator : allocatorObject;

    enum bool supportGC = true;

    //
    {
        auto s = RcPtr!long.make(42);
    }

    {
        auto s = RcPtr!long.make!(DefaultAllocator, supportGC)(42);
    }

    {
        auto s = RcPtr!(long, shared(SharedControlType)).make!(DefaultAllocator, supportGC)(42);
    }


    // dynamic array:
    {
        auto s = RcPtr!(long[]).make(10, 42);
        assert(s.length == 10);
    }

    {
        auto s = RcPtr!(long[]).make!(DefaultAllocator, supportGC)(10, 42);
        assert(s.length == 10);
    }

    {
        auto s = RcPtr!(long[], shared(SharedControlType)).make!(DefaultAllocator, supportGC)(10, 42);
        assert(s.length == 10);
    }
}

//alloc:
nothrow unittest{
    import std.experimental.allocator : allocatorObject;

    auto a = allocatorObject(Mallocator.instance);
    enum bool supportGC = true;

    //
    {
        auto s = RcPtr!long.alloc(a, 42);
    }

    {
        auto s = RcPtr!long.alloc!supportGC(a, 42);
    }

    {
        auto s = RcPtr!(long, shared(SharedControlType)).alloc!supportGC(a, 42);
    }


    // dynamic array:
    {
        auto s = RcPtr!(long[]).alloc(a, 10, 42);
        assert(s.length == 10);
    }

    {
        auto s = RcPtr!(long[]).alloc!supportGC(a, 10, 42);
        assert(s.length == 10);
    }

    {
        auto s = RcPtr!(long[], shared(SharedControlType)).alloc!supportGC(a, 10, 42);
        assert(s.length == 10);
    }
}



/**
    Dynamic cast for shared pointers if `ElementType` is class with D linkage.

    Creates a new instance of `RcPtr` whose stored pointer is obtained from `ptr`'s stored pointer using a dynaic cast expression.

    If `ptr` is null or dynamic cast fail then result `RcPtr` is null.
    Otherwise, the new `RcPtr` will share ownership with the initial value of `ptr`.
*/
public ChangeElementType!(Ptr, T) dynCast(T, Ptr)(ref scope Ptr ptr)
if(true
    && isRcPtr!Ptr && !is(Ptr == shared) && !Ptr.weakPtr
    && isReferenceType!T && __traits(getLinkage, T) == "D"
    && isReferenceType!(Ptr.ElementType) && __traits(getLinkage, Ptr.ElementType) == "D"
){
    static assert(isValidRcPtr!Ptr, "`Ptr` is invalid `RcPtr`");

    if(auto element = dynCastElement!T(ptr._element)){
        return typeof(return)(ptr._control, element);
    }

    return typeof(return).init;
}

/// ditto
public ChangeElementType!(Ptr, T) dynCast(T, Ptr)(scope Ptr ptr)
if(true
    && isRcPtr!Ptr && !is(Ptr == shared) && !Ptr.weakPtr
    && isReferenceType!T && __traits(getLinkage, T) == "D"
    && isReferenceType!(Ptr.ElementType) && __traits(getLinkage, Ptr.ElementType) == "D"
){
    static assert(isValidRcPtr!Ptr, "`Ptr` is invalid `RcPtr`");

    return dynCastMove!T(ptr);
}

/// ditto
public ChangeElementType!(Ptr, T) dynCastMove(T, Ptr)(auto ref scope Ptr ptr)
if(true
    && isRcPtr!Ptr && !is(Ptr == shared) && !Ptr.weakPtr
    && isReferenceType!T && __traits(getLinkage, T) == "D"
    && isReferenceType!(Ptr.ElementType) && __traits(getLinkage, Ptr.ElementType) == "D"
){
    static assert(isValidRcPtr!Ptr, "`Ptr` is invalid `RcPtr`");

    if(auto element = dynCastElement!T(ptr._element)){
        ptr._const_reset();
        return typeof(return)(element, Evoid.init);
    }

    return typeof(return).init;
}


///
unittest{
    static class Foo{
        int i;

        this(int i)pure nothrow @safe @nogc{
            this.i = i;
        }
    }

    static class Bar : Foo{
        double d;

        this(int i, double d)pure nothrow @safe @nogc{
            super(i);
            this.d = d;
        }
    }

    static class Zee{
    }

    {
        RcPtr!(const Foo) foo = RcPtr!Bar.make(42, 3.14);
        assert(foo.get.i == 42);

        auto bar = dynCast!Bar(foo);
        assert(bar != null);
        assert(bar.get.d == 3.14);
        static assert(is(typeof(bar) == RcPtr!(const Bar)));

        auto zee = dynCast!Zee(foo);
        assert(zee == null);
        static assert(is(typeof(zee) == RcPtr!(const Zee)));
    }

    {
        RcPtr!(const Foo) foo = RcPtr!Bar.make(42, 3.14);
        assert(foo.get.i == 42);

        auto bar = dynCast!Bar(foo.move);
        assert(bar != null);
        assert(bar.get.d == 3.14);
        static assert(is(typeof(bar) == RcPtr!(const Bar)));
    }

    {
        RcPtr!(const Foo) foo = RcPtr!Bar.make(42, 3.14);
        assert(foo.get.i == 42);

        auto bar = dynCastMove!Bar(foo);
        assert(foo == null);
        assert(bar != null);
        assert(bar.get.d == 3.14);
        static assert(is(typeof(bar) == RcPtr!(const Bar)));
    }
}



/**
    Create `SharedPtr` from parameter `ptr` of type `RcPtr`.
*/
auto sharedPtr(Ptr)(auto ref scope Ptr ptr)@trusted
if(isRcPtr!Ptr && !is(Ptr == shared)){
    import std.traits : CopyTypeQualifiers;
    import core.lifetime : forward;
    import autoptr.shared_ptr : SharedPtr;

    return SharedPtr!(
        CopyTypeQualifiers!(Ptr, Ptr.ElementType),
        Ptr.DestructorType,
        Ptr.ControlType,
        Ptr.weakPtr
    )(forward!ptr);
}


///
unittest{
    auto x = RcPtr!long.make(42);
    assert(*x == 42);
    assert(x.useCount == 1);

    auto s = sharedPtr(x);
    assert(x.useCount == 2);

    import autoptr.shared_ptr : isSharedPtr;
    static assert(isSharedPtr!(typeof(s)));

    auto s2 = sharedPtr(x.move);
    assert(s.useCount == 2);

    auto y = sharedPtr(RcPtr!long.init);
    assert(y == null);
}



/**
    Return `shared RcPtr` pointing to same managed object like parameter `ptr`.

    Type of parameter `ptr` must be `RcPtr` with `shared(ControlType)` and `shared`/`immutable` `ElementType` .
*/
public shared(Ptr) share(Ptr)(auto ref scope Ptr ptr)
if(isRcPtr!Ptr){
    static assert(isValidRcPtr!Ptr, "`Ptr` is invalid `RcPtr`");

    import core.lifetime : forward;
    static if(is(Ptr == shared)){
        return forward!ptr;
    }
    else{
        static assert(is(Ptr.ControlType == shared),
            "`RcPtr` has not shared ref counter `ControlType`."
        );

        static assert(is(Ptr.ElementType == shared) || is(Ptr.ElementType == immutable),
            "`RcPtr` has not shared/immutable `ElementType`."
        );

        static assert(isValidRcPtr!(typeof(return)),
            "`typeof(return)` is invalid `RcPtr`"
        );

        return typeof(return)(forward!ptr);
    }
}

///
nothrow @nogc unittest{
    {
        auto x = RcPtr!(shared long).make(123);
        assert(x.useCount == 1);

        shared s1 = share(x);
        assert(x.useCount == 2);


        shared s2 = share(x.move);
        assert(x == null);
        assert(s2.useCount == 2);
        assert(s2.load.get == 123);

    }

    {
        auto x = RcPtr!(long).make(123);
        assert(x.useCount == 1);

        ///error `shared RcPtr` need shared `ControlType` and shared `ElementType`.
        //shared s1 = share(x);

    }

}



/**
    Return `RcPtr` pointing to first element of dynamic array managed by rc pointer `ptr`.
*/
public auto first(Ptr)(scope ref Ptr ptr)@trusted
if(isValidRcPtr!Ptr && is(Ptr.ElementType : T[], T)){
    import std.traits : isDynamicArray, isStaticArray;
    import std.range : ElementEncodingType;

    alias Result = ChangeElementType!(
        Ptr,
        ElementEncodingType!(Ptr.ElementType)
    );

    if(ptr == null)
        return Result.init;

    static if(isDynamicArray!(Ptr.ElementType) || isStaticArray!(Ptr.ElementType)){
        return Result(ptr._control, ptr._element.ptr);
    }
    else static assert(0, "no impl");
}

/// ditto
public auto first(Ptr)(scope Ptr ptr)@trusted
if(isValidRcPtr!Ptr && is(Ptr.ElementType : T[], T)){
    import std.traits : isDynamicArray, isStaticArray;
    import std.range : ElementEncodingType;

    alias Result = ChangeElementType!(
        Ptr,
        ElementEncodingType!(Ptr.ElementType)
    );

    if(ptr == null)
        return Result.init;

    static if(isDynamicArray!(Ptr.ElementType) || isStaticArray!(Ptr.ElementType)){
        auto ptr_element = ptr._element.ptr;
        ptr._const_reset();
        return Result(ptr_element, Evoid.init);
    }
    else static assert(0, "no impl");
}

///
pure nothrow @nogc unittest{
    //copy
    {
        auto x = RcPtr!(long[]).make(10, -1);
        assert(x.length == 10);

        auto y = first(x);
        static assert(is(typeof(y) == RcPtr!long));
        assert(*y == -1);
        assert(x.useCount == 2);
    }

    {
        auto x = RcPtr!(long[10]).make(-1);
        assert(x.get.length == 10);

        auto y = first(x);
        static assert(is(typeof(y) == RcPtr!long));
        assert(*y == -1);
        assert(x.useCount == 2);
    }

    //move
    {
        auto x = RcPtr!(long[]).make(10, -1);
        assert(x.length == 10);

        auto y = first(x.move);
        static assert(is(typeof(y) == RcPtr!long));
        assert(*y == -1);
    }

    {
        auto x = RcPtr!(long[10]).make(-1);
        assert(x.get.length == 10);

        auto y = first(x.move);
        static assert(is(typeof(y) == RcPtr!long));
        assert(*y == -1);
    }
}



//local traits:
private{

    template weakLock(From, To)
    if(isRcPtr!From && isRcPtr!To){
        enum weakLock = (From.weakPtr && !To.weakPtr);
    }

    template isConstructable(From, To)
    if((isRcPtr!From || isUniquePtr!From) && isRcPtr!To){
        import std.traits : Unqual, CopyTypeQualifiers;

        alias FromPtr = CopyTypeQualifiers!(From, From.ElementReferenceType);
        alias ToPtr = CopyTypeQualifiers!(To, To.ElementReferenceType);

        static if(is(Unqual!(From.ElementType) == Unqual!(To.ElementType)))
            enum bool overlapable = true;

        else static if(isReferenceType!(From.ElementType) && isReferenceType!(To.ElementType))
            enum bool overlapable = true
                && (__traits(getLinkage, From.ElementType) == "D")
                && (__traits(getLinkage, To.ElementType) == "D");

        else
            enum bool overlapable = false;

        enum bool isConstructable = true
            && overlapable    //isOverlapable!(From.ElementType, To.ElementType) //&& is(Unqual!(From.ElementType) == Unqual!(To.ElementType))
            && is(FromPtr : ToPtr)
            && is(From.DestructorType : To.DestructorType)
            && is(From.ControlType == To.ControlType)            ;
    }

    template isAssignable(From, To)
    if(isRcPtr!From && isRcPtr!To){
        import std.traits : isMutable;

        enum bool isAssignable = true
            && isConstructable!(From, To)
            && !weakLock!(From, To)
            && isMutable!To;
    }
}


version(unittest){
    struct TestAllocator{
        static assert(stateSize!TestAllocator > 0);
        private int x;
        import std.experimental.allocator.common : platformAlignment, stateSize;

        enum uint alignment = platformAlignment;

        void[] allocate(size_t bytes)@trusted @nogc nothrow pure{
            import core.memory : pureMalloc;
            if (!bytes) return null;
            auto p = pureMalloc(bytes);
            return p ? p[0 .. bytes] : null;
        }

        bool deallocate(void[] b)@system @nogc nothrow pure{
            import core.memory : pureFree;
            pureFree(b.ptr);
            return true;
        }

        bool reallocate(ref void[] b, size_t s)@system @nogc nothrow pure{
            import core.memory : pureRealloc;
            if (!s){
                // fuzzy area in the C standard, see http://goo.gl/ZpWeSE
                // so just deallocate and nullify the pointer
                deallocate(b);
                b = null;
                return true;
            }

            auto p = cast(ubyte*) pureRealloc(b.ptr, s);
            if (!p) return false;
            b = p[0 .. s];
            return true;
        }

        //static TestAllocator instance;

    }

    //copy ctor
    pure nothrow @nogc unittest{


        static struct Test{}

        import std.meta : AliasSeq;
        //alias Test = long;
        static foreach(alias ControlType; AliasSeq!(SharedControlType, shared SharedControlType)){{
            alias SPtr(T) = RcPtr!(T, DestructorType!T, ControlType);

            //mutable:
            {
                alias Ptr = SPtr!(Test);
                Ptr ptr;
                static assert(__traits(compiles, Ptr(ptr)));
                static assert(__traits(compiles, const(Ptr)(ptr)));
                static assert(!__traits(compiles, immutable(Ptr)(ptr)));
                static assert(!__traits(compiles, shared(Ptr)(ptr)));
                static assert(!__traits(compiles, const(shared(Ptr))(ptr)));

                const(Ptr) cptr;
                static assert(!__traits(compiles, Ptr(cptr)));
                static assert(__traits(compiles, const(Ptr)(cptr)));
                static assert(!__traits(compiles, immutable(Ptr)(cptr)));
                static assert(!__traits(compiles, shared(Ptr)(cptr)));
                static assert(!__traits(compiles, const(shared(Ptr))(cptr)));

                immutable(Ptr) iptr;
                static assert(!__traits(compiles, Ptr(iptr)));
                static assert(__traits(compiles, const(Ptr)(iptr)));
                static assert(__traits(compiles, immutable(Ptr)(iptr)));
                static assert(!__traits(compiles, shared(Ptr)(iptr)));
                static assert(__traits(compiles, const(shared(Ptr))(iptr)) == is(ControlType == shared));

                shared(Ptr) sptr;
                static assert(!__traits(compiles, Ptr(sptr)));
                static assert(!__traits(compiles, const(Ptr)(sptr)));
                static assert(!__traits(compiles, immutable(Ptr)(sptr)));
                static assert(!__traits(compiles, shared(Ptr)(sptr)));   //need load
                static assert(!__traits(compiles, const shared Ptr(sptr)));  //need load
                shared(const(Ptr)) scptr;
                static assert(!__traits(compiles, Ptr(scptr)));
                static assert(!__traits(compiles, const(Ptr)(scptr)));
                static assert(!__traits(compiles, immutable(Ptr)(scptr)));
                static assert(!__traits(compiles, shared(Ptr)(scptr)));
                static assert(!__traits(compiles, const(shared(Ptr))(scptr)));  //need load
            }

            //const:
            {
                alias Ptr = SPtr!(const Test);
                Ptr ptr;
                static assert(__traits(compiles, Ptr(ptr)));
                static assert(__traits(compiles, const(Ptr)(ptr)));
                static assert(!__traits(compiles, immutable(Ptr)(ptr)));
                static assert(!__traits(compiles, shared(Ptr)(ptr)));
                static assert(!__traits(compiles, const(shared(Ptr))(ptr)));

                const(Ptr) cptr;
                static assert(__traits(compiles, Ptr(cptr)));
                static assert(__traits(compiles, const(Ptr)(cptr)));
                static assert(!__traits(compiles, immutable(Ptr)(cptr)));
                static assert(!__traits(compiles, shared(Ptr)(cptr)));
                static assert(!__traits(compiles, const(shared(Ptr))(cptr)));

                immutable(Ptr) iptr;
                static assert(__traits(compiles, Ptr(iptr)));
                static assert(__traits(compiles, const(Ptr)(iptr)));
                static assert(__traits(compiles, immutable(Ptr)(iptr)));
                static assert(__traits(compiles, shared(Ptr)(iptr)) == is(ControlType == shared));
                static assert(__traits(compiles, const(shared(Ptr))(iptr)) == is(ControlType == shared));

                shared(Ptr) sptr;
                static assert(!__traits(compiles, Ptr(sptr)));
                static assert(!__traits(compiles, const(Ptr)(sptr)));
                static assert(!__traits(compiles, immutable(Ptr)(sptr)));
                static assert(!__traits(compiles, shared(Ptr)(sptr)));          //need load
                static assert(!__traits(compiles, const shared Ptr(sptr)));     //need load
                shared(const(Ptr)) scptr;
                static assert(!__traits(compiles, Ptr(scptr)));
                static assert(!__traits(compiles, const(Ptr)(scptr)));
                static assert(!__traits(compiles, immutable(Ptr)(scptr)));
                static assert(!__traits(compiles, shared(Ptr)(scptr)));         //need load
                static assert(!__traits(compiles, const(shared(Ptr))(scptr)));  //need load
            }

            //immutable:
            {
                alias Ptr = SPtr!(immutable Test);
                Ptr ptr;
                static assert(__traits(compiles, Ptr(ptr)));
                static assert(__traits(compiles, const(Ptr)(ptr)));
                static assert(__traits(compiles, immutable(Ptr)(ptr)));
                static assert(__traits(compiles, shared(Ptr)(ptr)) == is(ControlType == shared));
                static assert(__traits(compiles, const(shared(Ptr))(ptr)) == is(ControlType == shared));

                const(Ptr) cptr;
                static assert(__traits(compiles, Ptr(cptr)));
                static assert(__traits(compiles, const(Ptr)(cptr)));
                static assert(__traits(compiles, immutable(Ptr)(cptr)));
                static assert(__traits(compiles, shared(Ptr)(cptr)) == is(ControlType == shared));
                static assert(__traits(compiles, const(shared(Ptr))(cptr)) == is(ControlType == shared));

                immutable(Ptr) iptr;
                static assert(__traits(compiles, Ptr(iptr)));
                static assert(__traits(compiles, const(Ptr)(iptr)));
                static assert(__traits(compiles, immutable(Ptr)(iptr)));
                static assert(__traits(compiles, shared(Ptr)(iptr)) == is(ControlType == shared));
                static assert(__traits(compiles, const(shared(Ptr))(iptr)) == is(ControlType == shared));

                shared(Ptr) sptr;
                static assert(!__traits(compiles, Ptr(sptr)));
                static assert(!__traits(compiles, const(Ptr)(sptr)));
                static assert(!__traits(compiles, immutable(Ptr)(sptr)));
                static assert(!__traits(compiles, shared(Ptr)(sptr)));          //need load
                static assert(!__traits(compiles, const shared Ptr(sptr)));     //need load
                shared(const(Ptr)) scptr;
                static assert(!__traits(compiles, Ptr(scptr)));
                static assert(!__traits(compiles, const(Ptr)(scptr)));
                static assert(!__traits(compiles, immutable(Ptr)(scptr)));
                static assert(!__traits(compiles, shared(Ptr)(scptr)));         //need load
                static assert(!__traits(compiles, const(shared(Ptr))(scptr)));  //need load
            }


            //shared:
            static if(is(ControlType == shared)){{
                alias Ptr = SPtr!(shared Test);
                Ptr ptr;
                static assert(__traits(compiles, Ptr(ptr)));
                static assert(__traits(compiles, const(Ptr)(ptr)));
                static assert(!__traits(compiles, immutable(Ptr)(ptr)));
                static assert(__traits(compiles, shared(Ptr)(ptr)));
                static assert(__traits(compiles, const(shared(Ptr))(ptr)));

                const(Ptr) cptr;
                static assert(!__traits(compiles, Ptr(cptr)));
                static assert(__traits(compiles, const(Ptr)(cptr)));
                static assert(!__traits(compiles, immutable(Ptr)(cptr)));
                static assert(!__traits(compiles, shared(Ptr)(cptr)));
                static assert(__traits(compiles, const(shared(Ptr))(cptr)));

                immutable(Ptr) iptr;
                static assert(!__traits(compiles, Ptr(iptr)));
                static assert(__traits(compiles, const(Ptr)(iptr)));
                static assert(__traits(compiles, immutable(Ptr)(iptr)));
                static assert(!__traits(compiles, shared(Ptr)(iptr)));
                static assert(__traits(compiles, const(shared(Ptr))(iptr)));

                shared(Ptr) sptr;
                static assert(!__traits(compiles, Ptr(sptr)));
                static assert(!__traits(compiles, const(Ptr)(sptr)));
                static assert(!__traits(compiles, immutable(Ptr)(sptr)));
                static assert(!__traits(compiles, shared(Ptr)(sptr)));          //need load
                static assert(!__traits(compiles, const shared Ptr(sptr)));     //need load
                shared(const(Ptr)) scptr;
                static assert(!__traits(compiles, Ptr(scptr)));
                static assert(!__traits(compiles, const(Ptr)(scptr)));
                static assert(!__traits(compiles, immutable(Ptr)(scptr)));
                static assert(!__traits(compiles, shared(Ptr)(scptr)));         //need load
                static assert(!__traits(compiles, const(shared(Ptr))(scptr)));  //need load
            }}


            //const shared:
            static if(is(ControlType == shared)){{
                alias Ptr = SPtr!(const shared Test);
                Ptr ptr;
                static assert(__traits(compiles, Ptr(ptr)));
                static assert(__traits(compiles, const(Ptr)(ptr)));
                static assert(!__traits(compiles, immutable(Ptr)(ptr)));
                static assert(__traits(compiles, shared(Ptr)(ptr)));
                static assert(__traits(compiles, const(shared(Ptr))(ptr)));

                const(Ptr) cptr;
                static assert(__traits(compiles, Ptr(cptr)));
                static assert(__traits(compiles, const(Ptr)(cptr)));
                static assert(!__traits(compiles, immutable(Ptr)(cptr)));
                static assert(__traits(compiles, shared(Ptr)(cptr)));
                static assert(__traits(compiles, const(shared(Ptr))(cptr)));

                immutable(Ptr) iptr;
                static assert(__traits(compiles, Ptr(iptr)));
                static assert(__traits(compiles, const(Ptr)(iptr)));
                static assert(__traits(compiles, immutable(Ptr)(iptr)));
                static assert(__traits(compiles, shared(Ptr)(iptr)));
                static assert(__traits(compiles, const(shared(Ptr))(iptr)));

                shared(Ptr) sptr;
                static assert(!__traits(compiles, Ptr(sptr)));
                static assert(!__traits(compiles, const(Ptr)(sptr)));
                static assert(!__traits(compiles, immutable(Ptr)(sptr)));
                static assert(!__traits(compiles, shared(Ptr)(sptr)));          //need load
                static assert(!__traits(compiles, const shared Ptr(sptr)));     //need load
                shared(const(Ptr)) scptr;
                static assert(!__traits(compiles, Ptr(scptr)));
                static assert(!__traits(compiles, const(Ptr)(scptr)));
                static assert(!__traits(compiles, immutable(Ptr)(scptr)));
                static assert(!__traits(compiles, shared(Ptr)(scptr)));         //need load
                static assert(!__traits(compiles, const(shared(Ptr))(scptr)));  //need load

            }}

        }}
    }

    //this(typeof(null))
    pure nothrow @safe @nogc unittest{
        RcPtr!long x = null;

        assert(x == null);
        assert(x == RcPtr!long.init);

    }


    //opAssign(RcPtr)
    pure nothrow @nogc unittest{

        {
            RcPtr!long px1 = RcPtr!long.make(1);
            RcPtr!long px2 = RcPtr!long.make(2);

            assert(px2.useCount == 1);
            px1 = px2;
            assert(px1.get == 2);
            assert(px2.useCount == 2);
        }



        {
            RcPtr!long px = RcPtr!long.make(1);
            RcPtr!(const long) pcx = RcPtr!long.make(2);

            assert(px.useCount == 1);
            pcx = px;
            assert(pcx.get == 1);
            assert(pcx.useCount == 2);

        }


        {
            const RcPtr!long cpx = RcPtr!long.make(1);
            RcPtr!(const long) pcx = RcPtr!long.make(2);

            assert(pcx.useCount == 1);
            pcx = cpx;
            assert(pcx.get == 1);
            assert(pcx.useCount == 2);

        }

        {
            RcPtr!(immutable long) pix = RcPtr!(immutable long).make(123);
            RcPtr!(const long) pcx = RcPtr!long.make(2);

            assert(pix.useCount == 1);
            pcx = pix;
            assert(pcx.get == 123);
            assert(pcx.useCount == 2);

        }
    }

    //opAssign(null)
    nothrow @safe @nogc unittest{
        {
            RcPtr!long x = RcPtr!long.make(1);

            assert(x.useCount == 1);
            x = null;
            assert(x.useCount == 0);
            assert(x == null);
        }

        {
            RcPtr!(shared long) x = RcPtr!(shared long).make(1);

            assert(x.useCount == 1);
            x = null;
            assert(x.useCount == 0);
            assert(x == null);
        }

        import autoptr.internal.mutex : supportMutex;
        static if(supportMutex){
            shared RcPtr!(long).ThreadLocal!false x = RcPtr!(shared long).ThreadLocal!false.make(1);

            assert(x.useCount == 1);
            x = null;
            assert(x.useCount == 0);
            assert(x.load == null);
        }
    }

    //useCount
    pure nothrow @safe @nogc unittest{
        RcPtr!long x = null;

        assert(x.useCount == 0);

        x = RcPtr!long.make(123);
        assert(x.useCount == 1);

        auto y = x;
        assert(x.useCount == 2);

        auto w1 = x.weak;    //weak ptr
        assert(x.useCount == 2);

        RcPtr!long.WeakType w2 = x;   //weak ptr
        assert(x.useCount == 2);

        y = null;
        assert(x.useCount == 1);

        x = null;
        assert(x.useCount == 0);
        assert(w1.useCount == 0);
    }

    //weakCount
    pure nothrow @safe @nogc unittest{

        RcPtr!long x = null;
        assert(x.useCount == 0);
        assert(x.weakCount == 0);

        x = RcPtr!long.make(123);
        assert(x.useCount == 1);
        assert(x.weakCount == 0);

        auto w = x.weak();
        assert(x.useCount == 1);
        assert(x.weakCount == 1);
    }

    // store:
    nothrow @nogc unittest{

        //null store:
        {
            shared x = RcPtr!(shared long).make(123);
            assert(x.load.get == 123);

            x.store(null);
            assert(x.useCount == 0);
            assert(x.load == null);
        }

        //rvalue store:
        {
            shared x = RcPtr!(shared long).make(123);
            assert(x.load.get == 123);

            x.store(RcPtr!(shared long).make(42));
            assert(x.load.get == 42);
        }

        //lvalue store:
        {
            shared x = RcPtr!(shared long).make(123);
            auto y = RcPtr!(shared long).make(42);

            assert(x.load.get == 123);
            assert(y.load.get == 42);

            x.store(y);
            assert(x.load.get == 42);
            assert(x.useCount == 2);
        }
    }

    //load:
    nothrow @nogc unittest{

        shared RcPtr!(long).ThreadLocal!false x = RcPtr!(shared long).ThreadLocal!false.make(123);

        import autoptr.internal.mutex : supportMutex;
        static if(supportMutex){
            RcPtr!(shared long) y = x.load();
            assert(y.useCount == 2);

            assert(y.get == 123);
        }

    }

    //exchange
    nothrow @nogc unittest{

        //lvalue exchange
        {
            shared x = RcPtr!(shared long).make(123);
            auto y = RcPtr!(shared long).make(42);

            auto z = x.exchange(y);

            assert(x.load.get == 42);
            assert(y.get == 42);
            assert(z.get == 123);
        }

        //rvalue exchange
        {
            shared x = RcPtr!(shared long).make(123);
            auto y = RcPtr!(shared long).make(42);

            auto z = x.exchange(y.move);

            assert(x.load.get == 42);
            assert(y == null);
            assert(z.get == 123);
        }

        //null exchange (same as move)
        {
            shared x = RcPtr!(shared long).make(123);

            auto z = x.exchange(null);

            assert(x.load == null);
            assert(z.get == 123);
        }

        //swap:
        {
            shared x = RcPtr!(shared long).make(123);
            auto y = RcPtr!(shared long).make(42);

            //opAssign is same as store
            y = x.exchange(y.move);

            assert(x.load.get == 42);
            assert(y.get == 123);
        }

    }


    //compareExchange
    pure nothrow @nogc unittest{
        static class Foo{
            long i;
            this(long i)pure nothrow @safe @nogc{
                this.i = i;
            }

            bool opEquals(this This)(long i)const @trusted{
                import std.traits : Unqual;
                auto self = cast(Unqual!This)this;
                return (self.i == i);
            }


        }
        alias Type = const Foo;
        static foreach(enum bool weak; [true, false]){
            //fail
            {
                RcPtr!Type a = RcPtr!Type.make(123);
                RcPtr!Type b = RcPtr!Type.make(42);
                RcPtr!Type c = RcPtr!Type.make(666);

                static if(weak)a.compareExchangeWeak(b, c);
                else a.compareExchangeStrong(b, c);

                assert(*a == 123);
                assert(*b == 123);
                assert(*c == 666);

            }

            //success
            {
                RcPtr!Type a = RcPtr!Type.make(123);
                RcPtr!Type b = a;
                RcPtr!Type c = RcPtr!Type.make(666);

                static if(weak)a.compareExchangeWeak(b, c);
                else a.compareExchangeStrong(b, c);

                assert(*a == 666);
                assert(*b == 123);
                assert(*c == 666);
            }

            //shared fail
            {
                shared RcPtr!(shared Type) a = RcPtr!(shared Type).make(123);
                RcPtr!(shared Type) b = RcPtr!(shared Type).make(42);
                RcPtr!(shared Type) c = RcPtr!(shared Type).make(666);

                static if(weak)a.compareExchangeWeak(b, c);
                else a.compareExchangeStrong(b, c);

                auto tmp = a.exchange(null);
                assert(*tmp == 123);
                assert(*b == 123);
                assert(*c == 666);
            }

            //shared success
            {
                RcPtr!(shared Type) b = RcPtr!(shared Type).make(123);
                shared RcPtr!(shared Type) a = b;
                RcPtr!(shared Type) c = RcPtr!(shared Type).make(666);

                static if(weak)a.compareExchangeWeak(b, c);
                else a.compareExchangeStrong(b, c);

                auto tmp = a.exchange(null);
                assert(*tmp == 666);
                assert(*b == 123);
                assert(*c == 666);
            }
        }

    }

    //lock
    nothrow @nogc unittest{
        {
            RcPtr!long x = RcPtr!long.make(123);

            auto w = x.weak;    //weak ptr

            RcPtr!long y = w.lock;

            assert(x == y);
            assert(x.useCount == 2);
            assert(y.get == 123);
        }

        {
            RcPtr!long x = RcPtr!long.make(123);

            auto w = x.weak;    //weak ptr

            assert(w.expired == false);

            x = RcPtr!long.make(321);

            assert(w.expired == true);

            RcPtr!long y = w.lock;

            assert(y == null);
        }
        {
            shared RcPtr!(shared long) x = RcPtr!(shared long).make(123);

            shared RcPtr!(shared long).WeakType w = x.load.weak;    //weak ptr

            assert(w.expired == false);

            x = RcPtr!(shared long).make(321);

            assert(w.expired == true);

            RcPtr!(shared long) y = w.load.lock;

            assert(y == null);
        }
    }

    //expired
    nothrow @nogc unittest{
        {
            RcPtr!long x = RcPtr!long.make(123);

            auto wx = x.weak;   //weak pointer

            assert(wx.expired == false);

            x = null;

            assert(wx.expired == true);
        }
    }

    //make
    pure nothrow @nogc unittest{
        {
            RcPtr!long a = RcPtr!long.make();
            assert(a.get == 0);

            RcPtr!(const long) b = RcPtr!long.make(2);
            assert(b.get == 2);
        }

        {
            static struct Struct{
                int i = 7;

                this(int i)pure nothrow @safe @nogc{
                    this.i = i;
                }
            }

            RcPtr!Struct s1 = RcPtr!Struct.make();
            assert(s1.get.i == 7);

            RcPtr!Struct s2 = RcPtr!Struct.make(123);
            assert(s2.get.i == 123);
        }

        static interface Interface{
        }
        static class Class : Interface{
            int i;

            this(int i)pure nothrow @safe @nogc{
                this.i = i;
            }
        }

        {

            RcPtr!Interface x = RcPtr!Class.make(3);
            //assert(x.dynTo!Class.get.i == 3);
        }


    }

    //make dynamic array
    pure nothrow @nogc unittest{
        {
            auto arr = RcPtr!(long[]).make(6, -1);
            assert(arr.length == 6);
            assert(arr.get.length == 6);

            import std.algorithm : all;
            assert(arr.get.all!(x => x == -1));

            for(long i = 0; i < 6; ++i)
                arr.get[i] = i;

            assert(arr.get == [0, 1, 2, 3, 4, 5]);
        }

        {
            static struct Struct{
                int i;
                double d;
            }

            {
                auto a = RcPtr!(Struct[]).make(6, 42, 3.14);
                assert(a.length == 6);
                assert(a.get.length == 6);

                import std.algorithm : all;
                assert(a.get[].all!(x => (x.i == 42 && x.d == 3.14)));
            }

            {
                auto a = RcPtr!(Struct[]).make(6);
                assert(a.length == 6);

                import std.algorithm : all;
                assert(a.get[].all!(x => (x.i == int.init)));
            }
        }

        {
            static class Class{
                int i;
                double d;

                this(int i, double d){
                    this.i = i;
                    this.d = d;
                }
            }

            {
                auto a = RcPtr!(Class[]).make(6, null);
                assert(a.length == 6);

                import std.algorithm : all;
                assert(a.get[].all!(x => x is null));
            }

            {
                auto a = RcPtr!(Class[]).make(6);
                assert(a.length == 6);

                import std.algorithm : all;
                assert(a.get[].all!(x => x is null));
            }


        }
    }

    //make static array
    pure nothrow @nogc unittest{
        import std.algorithm : all;
        {
            RcPtr!(long[6]) a = RcPtr!(long[6]).make();
            assert(a.get.length == 6);
            assert(a.get[].all!(x => x == long.init));
        }
        {
            RcPtr!(long[6]) a = RcPtr!(long[6]).make(-1);
            assert(a.get.length == 6);
            assert(a.get[].all!(x => x == -1));
        }
        {
            long[6] tmp = [1, 2, 3, 4, 5, 6];

            RcPtr!(const(long)[6]) a = RcPtr!(long[6]).make(tmp);
            assert(a.get.length == 6);
            assert(a.get[]== tmp);
        }
        {
            static struct Struct{
                int i;
                double d;
            }

            auto a = RcPtr!(Struct[6]).make(42, 3.14);
            assert(a.get.length == 6);

            import std.algorithm : all;
            assert(a.get[].all!(x => (x.i == 42 && x.d == 3.14)));


        }
    }

    //alloc
    pure nothrow @nogc unittest{
        {
            TestAllocator allocator;

            {
                RcPtr!long a = RcPtr!long.alloc(&allocator);
                assert(a.get == 0);

                RcPtr!(const long) b = RcPtr!long.alloc(&allocator, 2);
                assert(b.get == 2);
            }

            {
                static struct Struct{
                    int i = 7;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                RcPtr!Struct s1 = RcPtr!Struct.alloc(allocator);
                assert(s1.get.i == 7);

                RcPtr!Struct s2 = RcPtr!Struct.alloc(allocator, 123);
                assert(s2.get.i == 123);
            }

            static interface Interface{
            }
            static class Class : Interface{
                int i;

                this(int i)pure nothrow @safe @nogc{
                    this.i = i;
                }
            }

            {


                RcPtr!Interface x = RcPtr!Class.alloc(&allocator, 3);
                assert(x.useCount == 1);
                //assert(x.dynTo!Class.get.i == 3);
            }
        }
    }

    //alloc
    unittest{

        {
            import std.experimental.allocator : allocatorObject;

            auto a = allocatorObject(Mallocator.instance);
            {
                auto x = RcPtr!long.alloc(a);
                assert(x.get == 0);

                auto y = RcPtr!long.alloc(a, 2);
                assert(y.get == 2);
            }

            {
                static struct Struct{
                    int i = 7;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                auto s1 = RcPtr!Struct.alloc(a);
                assert(s1.get.i == 7);

                auto s2 = RcPtr!Struct.alloc(a, 123);
                assert(s2.get.i == 123);
            }

            {
                static interface Interface{
                }
                static class Class : Interface{
                    int i;

                    this(int i)pure nothrow @safe @nogc{
                        this.i = i;
                    }
                }

                RcPtr!(Interface, DestructorAllocatorType!(typeof(a))) x = RcPtr!Class.alloc(a, 3);
                //assert(x.dynTo!Class.get.i == 3);
            }

        }
    }

    //alloc array
    nothrow unittest{
        {
            import std.experimental.allocator : allocatorObject;

            auto a = allocatorObject(Mallocator.instance);
            auto arr = RcPtr!(long[], DestructorAllocatorType!(typeof(a))).alloc(a, 6, -1);
            assert(arr.length == 6);
            assert(arr.get.length == 6);

            import std.algorithm : all;
            assert(arr.get.all!(x => x == -1));

            for(long i = 0; i < 6; ++i)
                arr.get[i] = i;

            assert(arr.get == [0, 1, 2, 3, 4, 5]);
        }
    }

    //ctor
    pure nothrow @nogc @safe unittest{

        {
            RcPtr!long x = RcPtr!long.make(123);
            assert(x.useCount == 1);

            RcPtr!long a = x;         //lvalue copy ctor
            assert(a == x);

            const RcPtr!long b = x;   //lvalue copy ctor
            assert(b == x);

            RcPtr!(const long) c = x; //lvalue ctor
            assert(c == x);

            const RcPtr!long d = b;   //lvalue ctor
            assert(d == x);

            assert(x.useCount == 5);
        }

        {
            import core.lifetime : move;
            RcPtr!long x = RcPtr!long.make(123);
            assert(x.useCount == 1);

            RcPtr!long a = move(x);        //rvalue copy ctor
            assert(a.useCount == 1);

            const RcPtr!long b = move(a);  //rvalue copy ctor
            assert(b.useCount == 1);

            RcPtr!(const long) c = b.load;  //rvalue ctor
            assert(c.useCount == 2);

            const RcPtr!long d = move(c);  //rvalue ctor
            assert(d.useCount == 2);
        }

        {
            import core.lifetime : move;
            auto u = UniquePtr!(long, SharedControlType).make(123);

            RcPtr!long s = move(u);        //rvalue copy ctor
            assert(s != null);
            assert(s.useCount == 1);

            RcPtr!long s2 = UniquePtr!(long, SharedControlType).init;
            assert(s2 == null);

        }

    }

    //weak
    pure nothrow @nogc unittest{
        RcPtr!long x = RcPtr!long.make(123);
        assert(x.useCount == 1);
        auto wx = x.weak;   //weak pointer
        assert(wx.expired == false);
        assert(wx.lock.get == 123);
        assert(wx.useCount == 1);
        x = null;
        assert(wx.expired == true);
        assert(wx.useCount == 0);

    }

    //operator *
    pure nothrow @nogc unittest{

        RcPtr!long x = RcPtr!long.make(123);
        assert(*x == 123);
        (*x = 321);
        assert(*x == 321);
        const y = x;
        assert(*y == 321);
        assert(*x == 321);
        static assert(is(typeof(*y) == const long));
    }

    //get
    pure nothrow @nogc unittest{
        RcPtr!long x = RcPtr!long.make(123);
        assert(x.get == 123);
        x.get = 321;
        assert(x.get == 321);
        const y = x;
        assert(y.get == 321);
        assert(x.get == 321);
        static assert(is(typeof(y.get) == const long));
    }

    //element
    pure nothrow @nogc unittest{
        RcPtr!long x = RcPtr!long.make(123);
        assert(*x.element == 123);
        x.get = 321;
        assert(*x.element == 321);
        const y = x;
        assert(*y.element == 321);
        assert(*x.element == 321);
        static assert(is(typeof(y.element) == const(long)*));
    }

    //opCast bool
    @safe pure nothrow @nogc unittest{
        RcPtr!long x = RcPtr!long.make(123);
        assert(cast(bool)x);    //explicit cast
        assert(x);              //implicit cast
        x = null;
        assert(!cast(bool)x);   //explicit cast
        assert(!x);             //implicit cast
    }

    //opCast RcPtr
    @safe pure nothrow @nogc unittest{
        RcPtr!long x = RcPtr!long.make(123);
        auto y = cast(RcPtr!(const long))x;
        auto z = cast(const RcPtr!long)x;
        auto u = cast(const RcPtr!(const long))x;
        assert(x.useCount == 4);
    }

    //opEquals RcPtr
    pure @safe nothrow @nogc unittest{
        {
            RcPtr!long x = RcPtr!long.make(0);
            assert(x != null);
            x = null;
            assert(x == null);
        }

        {
            RcPtr!long x = RcPtr!long.make(123);
            RcPtr!long y = RcPtr!long.make(123);
            assert(x == x);
            assert(y == y);
            assert(x != y);
        }

        {
            RcPtr!long x;
            RcPtr!(const long) y;
            assert(x == x);
            assert(y == y);
            assert(x == y);
        }
    }

    //opEquals RcPtr
    pure nothrow @nogc unittest{
        {
            RcPtr!long x = RcPtr!long.make(123);
            RcPtr!long y = RcPtr!long.make(123);
            assert(x == x.element);
            assert(y.element == y);
            assert(x != y.element);
        }
    }

    //opCmp
    pure nothrow @safe @nogc unittest{
        {
            const a = RcPtr!long.make(42);
            const b = RcPtr!long.make(123);
            const n = RcPtr!long.init;

            assert(a <= a);
            assert(a >= a);

            assert((a < b) == !(a >= b));
            assert((a > b) == !(a <= b));

            assert(a > n);
            assert(a > null);

            assert(n < a);
            assert(null < a);
        }
    }

    //opCmp
    pure nothrow @nogc unittest{
        {
            const a = RcPtr!long.make(42);
            const b = RcPtr!long.make(123);

            assert(a <= a.element);
            assert(a.element >= a);

            assert((a < b.element) == !(a.element >= b));
            assert((a > b.element) == !(a.element <= b));
        }
    }

    //toHash
    pure nothrow @safe @nogc unittest{
        {
            RcPtr!long x = RcPtr!long.make(123);
            RcPtr!long y = RcPtr!long.make(123);
            assert(x.toHash == x.toHash);
            assert(y.toHash == y.toHash);
            assert(x.toHash != y.toHash);
            RcPtr!(const long) z = x;
            assert(x.toHash == z.toHash);
        }
        {
            RcPtr!long x;
            RcPtr!(const long) y;
            assert(x.toHash == x.toHash);
            assert(y.toHash == y.toHash);
            assert(x.toHash == y.toHash);
        }
    }

    //proxySwap
    pure nothrow @nogc unittest{
        {
            RcPtr!long a = RcPtr!long.make(1);
            RcPtr!long b = RcPtr!long.make(2);
            a.proxySwap(b);
            assert(*a == 2);
            assert(*b == 1);
            import std.algorithm : swap;
            swap(a, b);
            assert(*a == 1);
            assert(*b == 2);
            assert(a.useCount == 1);
            assert(b.useCount == 1);
        }
    }

    //length
    pure nothrow @nogc unittest{
        auto x = RcPtr!(int[]).make(10, -1);
        assert(x.length == 10);
        assert(x.get.length == 10);

        import std.algorithm : all;
        assert(x.get.all!(i => i == -1));
    }

}

pure nothrow @safe @nogc unittest{
    RcPtr!void u = RcPtr!void.make();
}