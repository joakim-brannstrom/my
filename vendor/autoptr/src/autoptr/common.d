/**
    Common code shared with other modules.

	License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
	Authors:   $(HTTP github.com/submada/basic_string, Adam Búš)
*/
module autoptr.common;

import std.meta : AliasSeq;
import std.stdio;

import autoptr.internal.traits;
import autoptr.internal.mallocator;


/**
    Type used as parameter for function pointer returned from `DestructorType`.
*/
public struct Evoid{

}


/**
    Default `ControlBlock` for `SharedPtr` and `RcPtr`.
*/
public alias SharedControlType = ControlBlock!(int, int);


/**
    Default `ControlBlock` for `UniquePtr`.
*/
public alias UniqueControlType = ControlBlock!void;


/**
    Default allcoator for `SharedPtr.make`, `RcPtr.make`, `UniquePtr.make` and `IntrusivePtr.make`.
*/
public alias DefaultAllocator = Mallocator;


//generate `DestructorTypes` alias
version(D_BetterC){}else
private string genDestructorTypes(){
    string result;
    result.reserve(16*40);

    import std.range : empty;
    foreach(string _pure; ["pure", ""])
    foreach(string _nothrow; ["nothrow", ""])
    foreach(string _safe; ["@safe", "@system"])
    foreach(string _nogc; ["@nogc", ""])
        result ~= "void function(void* )" ~ _pure
            ~ (_pure.empty?"":" ") ~ _nothrow
            ~ ((_pure.empty && _nothrow.empty)?"":" ") ~ _safe
            ~ ((_pure.empty && _nothrow.empty && _safe.empty)?"":" ") ~ _nogc
            ~ ",\n";

    return result;
}


//create all possible DestructorType types, DestructorType can return type with some hidden information and comparsion with it can fail (bug in D compiler).
//If type is created before calling DestructorType then DestructorType return existing type free of hidden informations and comparsion is ok.
/+public alias DestructorTypes = AliasSeq!(
    void function(Evoid* )pure nothrow @safe @nogc,
    void function(Evoid* )pure nothrow @safe,
    void function(Evoid* )pure nothrow @system @nogc,
    void function(Evoid* )pure nothrow @system,
    void function(Evoid* )pure @safe @nogc,
    void function(Evoid* )pure @safe,
    void function(Evoid* )pure @system @nogc,
    void function(Evoid* )pure @system,
    void function(Evoid* )nothrow @safe @nogc,
    void function(Evoid* )nothrow @safe,
    void function(Evoid* )nothrow @system @nogc,
    void function(Evoid* )nothrow @system,
    void function(Evoid* )@safe @nogc,
    void function(Evoid* )@safe,
    void function(Evoid* )@system @nogc,
    void function(Evoid* )@system,
);+/


/**
    Check if type `Type` is of type destructor type (is(void function(Evoid* )pure nothrow @safe @nogc : Type))
*/
public template isDestructorType(Type){
    enum bool isDestructorType = is(
        void function(Evoid* )pure nothrow @safe @nogc : Type
    );
}

///
unittest{
    static assert(isDestructorType!(void function(Evoid* )pure));
    static assert(isDestructorType!(DestructorType!long));
    static assert(!isDestructorType!(long));
}



/**
    Similiar to `DestructorType` but returns destructor attributes of type `Deleter` and attributes necessary to call variable of type `Deleter` with parameter of type `T`.
*/
public template DestructorDeleterType(T, Deleter){
    import std.traits : isCallable;

    static assert(isCallable!Deleter);

    static assert(__traits(compiles, (ElementReferenceTypeImpl!T elm){
        cast(void)Deleter.init(elm);
    }));

    alias Get(T) = T;

    static void impl()(Evoid*){
        ElementReferenceTypeImpl!T elm;

        Deleter deleter;

        cast(void)deleter(elm);
    }

    alias DestructorDeleterType = typeof(&impl!());

}



/**
    Similiar to `DestructorType` but returns destructor attributes of type `Allocator` and attributes of methods `void[] allocate(size_t)` and `void deallocate(void[])`.

    If method `allocate` is `@safe`/`@trusted` then method `deallocate` is assumed to be `@trusted` even if doesn't have `@safe`/`@trusted` attribute.
*/
public template DestructorAllocatorType(Allocator){
    import std.traits : Unqual, isPointer, PointerTarget, isAggregateType, hasMember;
    import std.range : ElementEncodingType;
    import std.meta : AliasSeq;

    import std.experimental.allocator.common : stateSize;

    static if(isPointer!Allocator)
        alias AllocatorType = PointerTarget!Allocator;
    else
        alias AllocatorType = Allocator;

    static assert(isAggregateType!AllocatorType);

    static assert(hasMember!(AllocatorType, "deallocate"));
    static assert(hasMember!(AllocatorType, "allocate"));

    static if(stateSize!Allocator == 0){
        static assert(__traits(compiles, (){
            const size_t size;
            void[] data = statelessAllcoator!Allocator.allocate(size);
        }()));

        static assert(__traits(compiles, (){
            void[] data;
            statelessAllcoator!Allocator.deallocate(data);
        }()));
    }
    else{
        static assert(__traits(compiles, (){
            const size_t size;
            Allocator.init.allocate(size);
        }()));

        static assert(__traits(compiles, (){
            void[] data;
            Allocator.init.deallocate(data);
        }()));
    }


    alias Get(T) = T;

    static void impl()(Evoid*){
        {
            Allocator allocator;
        }
        void[] data;
        const size_t size;

        static if(stateSize!Allocator == 0){
            enum bool safe_alloc = __traits(compiles, ()@safe{
                const size_t size;
                statelessAllcoator!Allocator.allocate(size);
            }());

            data = statelessAllcoator!Allocator.allocate(size);

            static if(safe_alloc)
                function(void[] data)@trusted{
                    statelessAllcoator!Allocator.deallocate(data);
                }(data);
            else
                statelessAllcoator!Allocator.deallocate(data);
        }
        else{
            enum bool safe_alloc = __traits(compiles, ()@safe{
                const size_t size;
                Allocator.init.allocate(size);
            }());

            data = Allocator.init.allocate(size);

            static if(safe_alloc)
                function(void[] data)@trusted{
                    Allocator.init.deallocate(data);
                }(data);
            else
                Allocator.init.deallocate(data);
        }

    }

    alias DestructorAllocatorType = typeof(&impl!());
}



/**
    Destructor type of destructors of types `Types` ( void function(Evoid*)@destructor_attributes ).
*/
public template DestructorType(Types...){
    import std.traits : Unqual, isDynamicArray, BaseClassesTuple;
    import std.range : ElementEncodingType;
    import std.meta : AliasSeq;

    alias Get(T) = T;

    static void impl()(Evoid*){

        static foreach(alias Type; Types){
            static if(is(Unqual!Type == void)){
                //nothing
            }
            else static if(is(Type == class)){
                // generate a body that calls all the destructors in the chain,
                // compiler should infer the intersection of attributes
                foreach (B; AliasSeq!(Type, BaseClassesTuple!Type)) {
                    // __dtor, i.e. B.~this
                    static if (__traits(hasMember, B, "__dtor"))
                        () { B obj; obj.__dtor; } ();
                    // __xdtor, i.e. dtors for all RAII members
                    static if (__traits(hasMember, B, "__xdtor"))
                        () { B obj; obj.__xdtor; } ();
                }
            }
            else static if(isDynamicArray!Type){
                {
                    ElementEncodingType!(Unqual!Type) tmp;
                }
            }
            else static if(is(void function(Evoid*)pure nothrow @safe @nogc : Unqual!Type)){
                {
                    Unqual!Type fn;
                    fn(null);
                }
            }
            else{
                {
                    Unqual!Type tmp;
                }
            }
        }
    }

    alias DestructorType = typeof(&impl!());
}

///
unittest{
    static assert(is(DestructorType!long == void function(Evoid*)pure nothrow @safe @nogc));


    static struct Struct{
        ~this()nothrow @system{
        }
    }
    static assert(is(DestructorType!Struct == void function(Evoid*)nothrow @system));


    version(D_BetterC)
        static extern(C)class Class{
            ~this()pure @trusted{

            }
        }
    else
        static class Class{
            ~this()pure @trusted{

            }
        }

    static assert(is(DestructorType!Class == void function(Evoid*)pure @safe));

    //multiple types:
    static assert(is(DestructorType!(Class, Struct, long) == void function(Evoid*)@system));

    static assert(is(
        DestructorType!(Class, DestructorType!long, DestructorType!Struct) == DestructorType!(Class, Struct, long)
    ));
}



/**
    This template deduce `ControlType` shared qualifier in `SharedPtr`, `RcPtr` and `UniquePtr`.

    If `Type` is shared then `ControlType` is shared too (atomic counting).
*/
public template ControlTypeDeduction(Type, ControlType){
    import std.traits : Select;

    alias ControlTypeDeduction = Select!(
        is(Type == shared), /+|| is(Type == immutable)+/
        shared(ControlType),
        ControlType
    );
}

///
unittest{
    alias ControlType = ControlBlock!(int, int);
    
    static assert(is(ControlTypeDeduction!(long, ControlType) == ControlType));
    static assert(is(ControlTypeDeduction!(void, ControlType) == ControlType));
    static assert(is(ControlTypeDeduction!(shared double, ControlType) == shared ControlType));
    static assert(is(ControlTypeDeduction!(const int, ControlType) == ControlType));
    static assert(is(ControlTypeDeduction!(shared const int, ControlType) == shared ControlType));

    static assert(is(ControlTypeDeduction!(immutable int, ControlType) == ControlType));    

    static assert(is(ControlTypeDeduction!(shared int[], ControlType) == shared ControlType));
    static assert(is(ControlTypeDeduction!(shared(int)[], ControlType) == ControlType));
}


/**
    Check if type `T` is of type `ControlBlock!(...)`.
*/
public template isControlBlock(T...)
if(T.length == 1){
    import std.traits : Unqual, isMutable;

    enum bool isControlBlock = is(
        Unqual!(T[0]) == ControlBlock!Args, Args...
    );
}

///
unittest{
    static assert(!isControlBlock!long);
    static assert(!isControlBlock!(void*));
    static assert(isControlBlock!(ControlBlock!long));  
    static assert(isControlBlock!(ControlBlock!(int, int)));
}


/**
    Control block for `SharedPtr`, `RcPtr`, `UniquePtr` and `IntrusivePtr`.

    Contains ref counting and dynamic dispatching for destruction and dealocation of managed object.

    Template parameters:

        `_Shared` signed integer for ref counting of `SharedPtr` or void if ref counting is not necessary (`UniquePtr` doesn't need ref counting).

        `_Weak` signed integer for weak ref counting of `SharedPtr` or void if weak pointer is not necessary.

*/
public template ControlBlock(_Shared, _Weak = void){
    import std.traits : Unqual, isUnsigned, isIntegral, isMutable;
    import core.atomic;

    static assert((isIntegral!_Shared && !isUnsigned!_Shared) || is(_Shared == void));
    static assert(is(Unqual!_Shared == _Shared));

    static assert((isIntegral!_Weak && !isUnsigned!_Weak) || is(_Weak == void));
    static assert(is(Unqual!_Weak == _Weak));

    struct ControlBlock{
        /**
            Signed integer for ref counting of `SharedPtr` or void if ref counting is not necessary (`UniquePtr`). 
        */
        public alias Shared = _Shared;

        /**
            Signed integer for weak ref counting of `SharedPtr` or void if weak counting is not necessary (`UniquePtr` or `SharedPtr` without weak ptr).
        */
        public alias Weak = _Weak;

        /**
            `true` if `ControlBlock` has ref counting (`Shared != void`).
        */
        public enum bool hasSharedCounter = !is(_Shared == void);

        /**
            `true` if `ControlBlock` has weak ref counting (`Weak != void`).
        */
        public enum bool hasWeakCounter = !is(_Weak == void);
        
        /**
            Copy constructor is @disabled.
        */
        public @disable this(scope ref const typeof(this) )scope pure nothrow @safe @nogc;

        /**
            Assign is @disabled.
        */
        public @disable void opAssign(scope ref const typeof(this) )scope pure nothrow @safe @nogc;


        //necessary for intrusive ptr
        package void initialize(this This)(immutable Vtable* vptr)scope pure nothrow @trusted @nogc{
            (cast(Unqual!This*)&this).vptr = vptr;
        }

        static assert(hasSharedCounter >= hasWeakCounter);

        package static struct Vtable{

            static if(hasSharedCounter)
            void function(ControlBlock*)pure nothrow @safe @nogc on_zero_shared;

            static if(hasWeakCounter)
            void function(ControlBlock*)pure nothrow @safe @nogc on_zero_weak;

            void function(ControlBlock*, bool)pure nothrow @safe @nogc manual_destroy;

            bool initialized()const pure nothrow @safe @nogc{
                return manual_destroy !is null;
            } 

            bool valid()const pure nothrow @safe @nogc{
                bool result = true;
                static if(hasSharedCounter){
                    if(on_zero_shared is null)
                        return false;
                }
                static if(hasWeakCounter){
                    if(on_zero_weak is null)
                        return false;
                }

                return manual_destroy !is null;
            }
        }

        private immutable(Vtable)* vptr;

        static if(hasSharedCounter)
            private Shared shared_count = 0;

        static if(hasWeakCounter)
            private Weak weak_count = 0;

        package this(this This)(immutable Vtable* vptr)pure nothrow @safe @nogc
        if(isMutable!This){
            assert(vptr !is null);
            this.vptr = vptr;
        }

        package final auto count(bool weak)()scope const pure nothrow @safe @nogc{
            static if(weak){
                static if(hasWeakCounter)
                    return this.weak_count;
                else
                    return int.init;
            }
            else{
                static if(hasSharedCounter)
                    return this.shared_count;
                else
                    return int.max;
            }

        }
        package final auto count(bool weak)()scope shared const pure nothrow @safe @nogc{
            static if(weak){
                static if(hasWeakCounter)
                    return atomicLoad(this.weak_count);
                else
                    return int.init;
            }
            else{
                static if(hasSharedCounter)
                    return atomicLoad(this.shared_count);
                else
                    return int.max;
            }

        }


        package final void add(bool weak, this This)()scope @trusted pure nothrow @nogc
        if(isMutable!This){
            enum bool atomic = is(This == shared);

            static if(weak){
                static if(hasWeakCounter){
                    rc_increment!atomic(this.weak_count);
                }
            }
            else{
                static if(hasSharedCounter){
                    rc_increment!atomic(this.shared_count);
                }
            }
        }
        package final void release(bool weak, this This)()@trusted pure nothrow @nogc
        if(isMutable!This){
            enum bool atomic = is(This == shared);

            static if(weak){
                static if(hasWeakCounter){
                    static if(atomic){
                        if(atomicLoad!(MemoryOrder.acq)(this.weak_count) == 0)
                            this.on_zero_weak();

                        else if(rc_decrement!atomic(this.weak_count) == -1)
                            this.on_zero_weak();
                    }
                    else{
                        if(this.weak_count == 0)
                            this.on_zero_weak();
                        else if(rc_decrement!atomic(this.weak_count) == -1)
                            this.on_zero_weak();
                    }
                }
            }
            else{
                static if(hasSharedCounter){
                    if(rc_decrement!atomic(this.shared_count) == -1){
                        //auto tmp = &this;
                        //auto self = &this;
                        this.on_zero_shared();

                        this.release!true;
                    }
                }
            }
        }

        static if(hasSharedCounter){
            package final bool add_shared_if_exists()@trusted pure nothrow @nogc{

                if(this.shared_count == -1){
                    return false;
                }
                this.shared_count += 1;
                return true;
            }

            package final bool add_shared_if_exists()shared @trusted pure nothrow @nogc{
                auto owners = atomicLoad(this.shared_count);

                while(owners != -1){
                    import core.atomic;
                    if(casWeak(&this.shared_count,
                        &owners,
                        cast(Shared)(owners + 1)
                    )){
                        return true;
                    }
                }

                return false;
            }
        }

        static if(hasSharedCounter)
        package void on_zero_shared(this This)()pure nothrow @nogc @trusted{
            this.vptr.on_zero_shared(cast(ControlBlock*)&this);
        }

        static if(hasWeakCounter)
        package void on_zero_weak(this This)()pure nothrow @nogc @trusted{
            this.vptr.on_zero_weak(cast(ControlBlock*)&this);
        }

        package void manual_destroy(this This)(bool dealocate)pure nothrow @nogc @trusted{
            this.vptr.manual_destroy(cast(ControlBlock*)&this, dealocate);
        }
    }
}


///
unittest{
    static assert(is(ControlBlock!(int, long).Shared == int));
    static assert(is(ControlBlock!(int, long).Weak == long));
    static assert(is(ControlBlock!int.Shared == int));
    static assert(is(ControlBlock!int.Weak == void));

    static assert(ControlBlock!(int, int).hasSharedCounter);
    static assert(ControlBlock!(int, int).hasWeakCounter);

    static assert(is(ControlBlock!int == ControlBlock!(int, void)));  
    static assert(ControlBlock!int.hasSharedCounter);   
    static assert(ControlBlock!int.hasWeakCounter == false);

    static assert(ControlBlock!void.hasSharedCounter == false);
    static assert(ControlBlock!void.hasWeakCounter == false);
}



/**
    Check if type `T` is of type `MutableControlBlock!(...)`.
*/
public template isMutableControlBlock(T...)
if(T.length == 1){
    import std.traits : Unqual;

    enum bool isMutableControlBlock = is(
        Unqual!(T[0]) == MutableControlBlock!Args, Args...
    );
}


import std.traits : isIntegral;

/**
    Mutable intrusive `ControlBlock`, this control block can be modified even if is `const` / `immutable`.

    Necessary for `IntrusivePtr`.
    
    Examples are in `IntrusiveControlBlock`.
*/
template MutableControlBlock(_Shared, _Weak = void)
if(isIntegral!_Shared){
    import std.traits : Unqual, isUnsigned, isIntegral, isMutable;

    static assert(isIntegral!_Shared && !isUnsigned!_Shared || is(_Weak == void));
    static assert(is(Unqual!_Shared == _Shared));

    static assert((isIntegral!_Weak && !isUnsigned!_Weak) || is(_Weak == void));
    static assert(is(Unqual!_Weak == _Weak));

    alias MutableControlBlock = MutableControlBlock!(ControlBlock!(_Shared, _Weak));
}

/// ditto
template MutableControlBlock(_ControlType)
if(isControlBlock!_ControlType){
    import std.traits : isMutable;

    static assert(isMutable!_ControlType);

    struct MutableControlBlock{
        public alias ControlType = _ControlType;

        private ControlType control;
    }
}


/**
    Return number of `ControlBlock`s in type `Type`.

    `IntrusivePtr` need exact `1` control block.
*/
public template isIntrusive(Type){
    static if(is(Type == struct)){
        enum size_t impl = isIntrusiveStruct!(Type)();
    }
    else static if(is(Type == class)){
        enum size_t impl = isIntrusiveClass!(Type, false)();
    }
    else{
        enum size_t impl = 0;
    }

    enum size_t isIntrusive = impl;
}

///
unittest{
    static assert(isIntrusive!long == 0);

    static assert(isIntrusive!(ControlBlock!int) == 0);

    static class Foo{
        long x;
        ControlBlock!int control;
    }

    static assert(isIntrusive!Foo == 1);

    static struct Struct{
        long x;
        ControlBlock!int control;
        Foo foo;
    }
    static assert(isIntrusive!Struct == 1);


    static class Bar : Foo{
        const ControlBlock!int control2;
        Struct s;

    }
    static assert(isIntrusive!Bar == 2);


    static class Zee{
        long l;
        double x;
        Struct str;
    }
    static assert(isIntrusive!Zee == 0);

}

private size_t isIntrusiveClass(Type, bool ignoreBase)()pure nothrow @safe @nogc
if(is(Type == class)){
    import std.traits : BaseClassesTuple;

    Type ty = null;

    size_t result = 0;

    static foreach(alias T; typeof(ty.tupleof)){
        static if(is(T == struct) && (isControlBlock!T || isMutableControlBlock!T))
            result += 1;
    }

    static if(!ignoreBase)
    static foreach(alias T; BaseClassesTuple!Type){
        result += isIntrusiveClass!(T, true);
    }

    return result;

}

private size_t isIntrusiveStruct(Type)()pure nothrow @safe @nogc
if(is(Type == struct)){
    Type* ty = null;

    size_t result = 0;

    static foreach(alias T; typeof((*ty).tupleof)){
        static if(is(T == struct) && (isControlBlock!T || isMutableControlBlock!T))
            result += 1;
    }

    return result;
}



/**
    Alias to `ControlBlock` including qualifiers contained by `Type`.

    If `mutable` is `true`, then result type alias is mutable (can be shared).
*/
public template IntrusiveControlBlock(Type, bool mutable = false)
if(isIntrusive!Type && is(Type == class) || is(Type == struct)){

    static if(is(Type == class))
        alias PtrControlBlock = typeof(intrusivControlBlock(Type.init));
    else static if(is(Type == struct))
        alias PtrControlBlock = typeof(intrusivControlBlock(*cast(Type*)null));
    else 
        static assert(0, "no impl");


    import std.traits : CopyTypeQualifiers, PointerTarget, Unconst;

    static if(mutable && is(PtrControlBlock == shared))
        alias IntrusiveControlBlock = shared(Unconst!(PointerTarget!PtrControlBlock));
    else
        alias IntrusiveControlBlock = PointerTarget!PtrControlBlock;
    
}

///
unittest{
    static class Foo{
        ControlBlock!int c;
    }

    static assert(is(
        IntrusiveControlBlock!(Foo) == ControlBlock!int
    ));
    static assert(is(
        IntrusiveControlBlock!(const Foo) == const ControlBlock!int
    ));
    static assert(is(
        IntrusiveControlBlock!(shared Foo) == shared ControlBlock!int
    ));
    static assert(is(
        IntrusiveControlBlock!(const shared Foo) == const shared ControlBlock!int
    ));
    static assert(is(
        IntrusiveControlBlock!(immutable Foo) == immutable ControlBlock!int
    ));



    static class Bar{
        MutableControlBlock!int c;
    }

    static assert(is(
        IntrusiveControlBlock!(Bar) == ControlBlock!int
    ));
    static assert(is(
        IntrusiveControlBlock!(const Bar) == ControlBlock!int
    ));
    static assert(is(
        IntrusiveControlBlock!(shared Bar) == shared ControlBlock!int
    ));
    static assert(is(
        IntrusiveControlBlock!(const shared Bar) == shared ControlBlock!int
    ));
    static assert(is(
        IntrusiveControlBlock!(immutable Bar) == ControlBlock!int
    ));



    static class Zee{
        shared MutableControlBlock!int c;
    }

    static assert(is(
        IntrusiveControlBlock!(Zee) == shared ControlBlock!int
    ));
    static assert(is(
        IntrusiveControlBlock!(const Zee) == shared ControlBlock!int
    ));
    static assert(is(
        IntrusiveControlBlock!(shared Zee) == shared ControlBlock!int
    ));
    static assert(is(
        IntrusiveControlBlock!(const shared Zee) == shared ControlBlock!int
    ));
    static assert(is(
        IntrusiveControlBlock!(immutable Zee) == shared ControlBlock!int
    ));


}



//mutex:
package static auto lockPtr(alias fn, Ptr, Args...)
(auto ref scope shared Ptr ptr, auto ref scope return Args args){
    import std.traits : CopyConstness, CopyTypeQualifiers, Unqual;
    import core.lifetime : forward;
    import autoptr.internal.mutex : getMutex;

    shared mutex = getMutex(ptr);

    mutex.lock();
    scope(exit)mutex.unlock();

    alias Result = ChangeElementType!(
        Unshared!Ptr,
        CopyTypeQualifiers!(shared Ptr, Ptr.ElementType)
    );


    return fn(
        *(()@trusted => cast(Result*)&ptr )(),
        forward!args
    );
}


/*
    Change `ElementType` for type 'SharedPtr', `RcPtr`, `IntrusivePtr` or `UniquePtr`.
*/
package template ChangeElementType(Ptr, T){
    import std.traits : CopyTypeQualifiers;

    alias FromType = CopyTypeQualifiers!(Ptr, Ptr.ElementType);
    alias ResultType = CopyTypeQualifiers!(FromType, T);

    static if(is(Ptr : SmartPtr!(OldType, Args), alias SmartPtr, OldType, Args...)){
        alias ChangeElementType = SmartPtr!(
            ResultType,
            Args
        );
    }
    else static assert(0, "no impl");
}


package template GetElementReferenceType(Ptr){
    import std.traits : CopyTypeQualifiers;

    alias ElementType = CopyTypeQualifiers!(Ptr, Ptr.ElementType);

    alias GetElementReferenceType = ElementReferenceTypeImpl!ElementType;
}

package template ElementReferenceTypeImpl(Type){
    import std.traits : Select, isDynamicArray;
    import std.range : ElementEncodingType;

    static if(isDynamicArray!Type)
        alias ElementReferenceTypeImpl = ElementEncodingType!Type[];
    else
        alias ElementReferenceTypeImpl = PtrOrRef!Type;

}


import std.traits : BaseClassesTuple, Unqual, Unconst, CopyTypeQualifiers;
import std.meta : AliasSeq;

/*
    Return pointer to qualified control block.
    Pointer is mutable and can be shared if control block is shared.
    For example if control block is immutable, then return type can be immtuable(ControlBlock)* or shared(immutable(ControlBlock)*).
    If result pointer is shared then atomic ref counting is necessary.
*/
package auto intrusivControlBlock(Type)(scope return auto ref Type elm)pure nothrow @trusted @nogc{

    static if(is(Type == struct)){
        static if(isControlBlock!Type){
            static if(is(Type == shared))
                return cast(CopyTypeQualifiers!(shared(void), Type*))&elm;
            else
                return &elm;
        }
        else static if(isMutableControlBlock!Type){
            auto control = intrusivControlBlock(elm.control);

            static if(is(Type == shared) || is(typeof(Unqual!Type.control) == shared))
                return cast(shared(Unconst!(typeof(*control))*))control;
            else
                return cast(Unconst!(typeof(*control))*)control;
        }
        else{
            static assert(isIntrusive!(Unqual!Type) == 1);

            foreach(ref x; (*cast(Unqual!(typeof(elm))*)&elm).tupleof){
                static if(isControlBlock!(typeof(x)) || isMutableControlBlock!(typeof(x))){
                    auto control = intrusivControlBlock(*cast(CopyTypeQualifiers!(Type, typeof(x))*)&x);

                    static if(is(Type == shared) || is(typeof(x) == shared))
                        return cast(CopyTypeQualifiers!(shared(void), typeof(control)))control;
                    else
                        return control;
                }
            }
        }
    }
    else static if(is(Type == class)){
        static assert(isIntrusive!(Unqual!Type) == 1);

        static if(isIntrusiveClass!(Type, true)){
            foreach(ref x; (cast(Unqual!(typeof(elm)))elm).tupleof){
                static if(isControlBlock!(typeof(x)) || isMutableControlBlock!(typeof(x))){
                    auto control = intrusivControlBlock(*cast(CopyTypeQualifiers!(Type, typeof(x))*)&x);

                    static if(is(Type == shared) || is(typeof(x) == shared))
                        return cast(CopyTypeQualifiers!(shared(void), typeof(control)))control;
                    else
                        return control;
                }
            }

        }
        else static foreach(alias T; BaseClassesTuple!Type){
            static if(isIntrusiveClass!(T, true)){

                foreach(ref x; (cast(Unqual!T)elm).tupleof){
                    static if(isControlBlock!(typeof(x)) || isMutableControlBlock!(typeof(x))){
                        auto control = intrusivControlBlock(*cast(CopyTypeQualifiers!(Type, typeof(x))*)&x);

                        static if(is(Type == shared) || is(typeof(x) == shared))
                            return cast(CopyTypeQualifiers!(shared(void), typeof(control)))control;
                        else
                            return control;
                    }
                }

            }
        }
    }
    else static assert(0, "no impl");
}

//control block
unittest{
    import std.traits : lvalueOf;
    static struct Foo{
        ControlBlock!int c;
    }

    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!Foo)) == ControlBlock!int*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(shared Foo))) == shared ControlBlock!int*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(const Foo))) == const(ControlBlock!int)*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(shared const Foo))) == shared const(ControlBlock!int)*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(immutable Foo))) == immutable(ControlBlock!int)*
    ));
}

//shared control block
unittest{
    import std.traits : lvalueOf;
    static struct Foo{
        shared ControlBlock!int c;
    }

    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!Foo)) == shared ControlBlock!int*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(shared Foo))) == shared ControlBlock!int*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(const Foo))) == shared const(ControlBlock!int)*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(shared const Foo))) == shared const(ControlBlock!int)*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(immutable Foo))) == shared immutable(ControlBlock!int)*
    ));
}

//mutable control block
unittest{
    import std.traits : lvalueOf;
    static struct Foo{
        MutableControlBlock!int c;
    }

    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!Foo)) == ControlBlock!int*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(shared(Foo)))) == shared ControlBlock!int*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(const Foo))) == ControlBlock!int*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(shared const Foo))) == shared ControlBlock!int*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(immutable Foo))) == ControlBlock!int*
    ));
}

//shared mutable control block
unittest{
    import std.traits : lvalueOf;
    static struct Foo{
        shared MutableControlBlock!int c;
    }

    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!Foo)) == shared ControlBlock!int*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(shared(Foo)))) == shared ControlBlock!int*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(const Foo))) == shared ControlBlock!int*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(shared const Foo))) == shared ControlBlock!int*
    ));
    static assert(is(
        typeof(intrusivControlBlock(lvalueOf!(immutable Foo))) == shared ControlBlock!int*
    ));
}




package auto dynCastElement(To, From)(scope return From from)pure nothrow @trusted @nogc
if(isReferenceType!From && isReferenceType!To){
    import std.traits : CopyTypeQualifiers, Unqual;

    alias Result = CopyTypeQualifiers!(From, To);

    return (from is null)
        ? Result.init
        : cast(Result)cast(Unqual!To)cast(Unqual!From)from;
}


//Return offset of intrusive control block in Type.
package size_t intrusivControlBlockOffset(Type)()pure nothrow @safe @nogc{
    static assert(isIntrusive!(Unqual!Type) == 1);
    
    static if(is(Type == struct)){
        static foreach(alias var; Type.tupleof){
            static if(isControlBlock!(typeof(var)) || isMutableControlBlock!(typeof(var)))
                return var.offsetof;
        }
    }
    else static if(is(Type == class)){
        static if(isIntrusiveClass!(Type, true)){
            static foreach(alias var; Type.tupleof){
                static if(isControlBlock!(typeof(var)) || isMutableControlBlock!(typeof(var)))
                    return var.offsetof;

            }
        }
        else static foreach(alias T; BaseClassesTuple!Type){
            static if(isIntrusiveClass!(T, true)){
                static foreach(alias var; T.tupleof){
                    static if(isControlBlock!(typeof(var)) || isMutableControlBlock!(typeof(var)))
                        return var.offsetof;
                }
            }
        }
    }
    else static assert(0, "no impl");
}

unittest{
    static assert(isIntrusive!long == 0);
    static assert(isIntrusive!(ControlBlock!int) == 0);

    static class Foo{
        long x;
        ControlBlock!int control;
    }


    {
        Foo foo;
        auto control = intrusivControlBlock(foo);
    }


    static assert(isIntrusive!Foo == 1);
    static assert(Foo.control.offsetof == intrusivControlBlockOffset!Foo());

    static struct Struct{
        long x;
        ControlBlock!int control;
        Foo foo;
    }

    static assert(isIntrusive!Struct == 1);
    static assert(Struct.control.offsetof == intrusivControlBlockOffset!Struct());


    static class Bar : Foo{
        ControlBlock!int control2;
        Struct s;

    }

    static assert(isIntrusive!Bar == 2);
}

/+
import std.traits : isMutable, isBasicType, 
    isPointer, PointerTarget,
    isArray;
import std.range : ElementEncodingType;

template isSafeCtorCallArg(T){

    static if(!isMutable!T || isBasicType!T || is(immutable T == immutable typeof(null)))
        enum bool isSafeCtorCallArg = true;

    else static if(isPointer!T)
        enum bool isSafeCtorCallArg = .isSafeCtorCallArg!(PointerTarget!T);

    else static if(isArray!T)
        enum bool isSafeCtorCallArg = .isSafeCtorCallArg!(ElementEncodingType!T);

    else
        enum bool isSafeCtorCallArg = false;
}

/*
    Return `true` if type `T` can be constructed with parameters `Args` in @safe code.
*/
template hasSafeCtorCall(T){
    static if(is(T == struct) || is(T == union) || is(T == class)){
        bool hasSafeCtorCall(Args...)(auto ref Args args){
            import core.lifetime : forward;
            T chunk;

            static if(is(typeof(chunk.__ctor(forward!args)))){
                import std.traits : isMutable, isBasicType, isPointer, PointerTarget;
                bool safe = true;

                static foreach(alias Arg; Args)
                    safe = isSafeCtorCallArg!Arg;   

                return safe;
            }
            else{
                return true;
            }
        }
    }
    else{
        bool hasSafeCtorCall(Args...)(auto ref Args args){
            return true;
        }
    }
}+/


/*
    same as core.lifetime.emplace but limited for intrusive class and struct.
    initialize vptr for intrusive control block before calling ctor of class/struct. 
*/
package void emplaceIntrusive(T, Vptr, Args...)(auto ref T chunk, immutable Vptr* vptr, auto ref Args args)
if(isIntrusive!T){
    static assert(is(T == struct) || is(T == class));
    assert(vptr !is null);

    ()@trusted{
        static if(is(T == struct)){
            import core.internal.lifetime : emplaceInitializer;

            emplaceInitializer(*cast(Unqual!T*)&chunk);
        }
        else static if(is(T == class)){
            // Initialize the object in its pre-ctor state
            enum classSize = __traits(classInstanceSize, T);
            (cast(void*) chunk)[0 .. classSize] = typeid(T).initializer[];  //(() @trusted => (cast(void*) chunk)[0 .. classSize] = typeid(T).initializer[])();
        }
        else static assert(0, "no impl");

    }();

    auto control = intrusivControlBlock(chunk);
    control.initialize(vptr);

    import core.lifetime : forward, emplace;


    static if (args.length == 0){
        static assert(is(typeof({static T i;})),
            "Cannot emplace a " ~ T.stringof ~ " because " ~ T.stringof ~
            ".this() is annotated with @disable."
        );

        //emplaceInitializer(chunk);
    }

    // Call the ctor if any
    else static if (is(typeof(chunk.__ctor(forward!args)))){
        // T defines a genuine constructor accepting args
        // Go the classic route: write .init first, then call ctor
        chunk.__ctor(forward!args);
    }
    else{
        static assert(args.length == 0 && !is(typeof(&T.__ctor)),
            "Don't know how to initialize an object of type "
            ~ T.stringof ~ " with arguments " ~ typeof(args).stringof);
    }

}

package template MakeEmplace(_Type, _DestructorType, _ControlType, _AllocatorType, bool supportGC){
    import core.lifetime : emplace;
    import std.traits: hasIndirections, isAbstractClass, isMutable, isDynamicArray,
        Select, CopyTypeQualifiers,
        Unqual, Unconst, PointerTarget;

    static assert(isIntrusive!_Type == 0);
    
    static assert(!isAbstractClass!_Type,
        "cannot create object of abstract class" ~ Unqual!_Type.stringof
    );
    static assert(!is(_Type == interface),
        "cannot create object of interface type " ~ Unqual!_Type.stringof
    );

    static if(!isDynamicArray!_Type)
    static assert(is(DestructorType!_Type : _DestructorType));

    static assert(is(DestructorAllocatorType!_AllocatorType : _DestructorType),
        "allocator attributes `" ~ DestructorAllocatorType!_AllocatorType.stringof ~ "`" ~
        "doesn't support destructor attributes `" ~ _DestructorType.stringof
    );


    alias AllocatorWithState = .AllocatorWithState!_AllocatorType;

    enum bool hasStatelessAllocator = (AllocatorWithState.length == 0);

    enum bool hasWeakCounter = _ControlType.hasWeakCounter;

    enum bool hasSharedCounter = _ControlType.hasSharedCounter;

    enum bool allocatorGCRange = supportGC
        && !hasStatelessAllocator
        && hasIndirections!_AllocatorType;

    enum bool dataGCRange = supportGC
        && (false
            || classHasIndirections!_Type
            || hasIndirections!_Type
            || (is(_Type == class) && is(Unqual!_Type : Object))
        );

    alias Vtable = _ControlType.Vtable;


    struct MakeEmplace{
        private static immutable Vtable vtable;

        private _ControlType control;
        private void[instanceSize!_Type] data;

        static if(!hasStatelessAllocator)
            private _AllocatorType allocator;

        static assert(control.offsetof + typeof(control).sizeof == data.offsetof);

        version(D_BetterC)
            private static void shared_static_this()pure nothrow @safe @nogc{
                assumePure((){
                    Vtable* vptr = cast(Vtable*)&vtable;
                    
                    static if(hasSharedCounter)
                        vptr.on_zero_shared = &virtual_on_zero_shared;

                    static if(hasWeakCounter)
                        vptr.on_zero_weak = &virtual_on_zero_weak;

                    vptr.manual_destroy = &virtual_manual_destroy;
                })();

            }
        else
            shared static this()nothrow @safe @nogc{
                static if(hasWeakCounter){
                    vtable = Vtable(
                        &virtual_on_zero_shared,
                        &virtual_on_zero_weak,
                        &virtual_manual_destroy
                    );
                }
                else static if(hasSharedCounter){
                    vtable = Vtable(
                        &virtual_on_zero_shared,
                        &virtual_manual_destroy
                    );
                }
                else vtable = Vtable(
                    &virtual_manual_destroy
                );
            }


        public @property _ControlType* base()return scope pure nothrow @trusted @nogc{
            //static assert(this.control.offsetof == 0);
            /+return function _ControlType*(ref _ControlType ct)@trusted{
                return &ct;
            }(this.control);+/
            return &this.control;
        }

        public @property PtrOrRef!_Type get()pure nothrow @trusted @nogc{
            return cast(PtrOrRef!_Type)this.data.ptr;
        }




        public static MakeEmplace* make(Args...)(AllocatorWithState[0 .. $] a, auto ref Args args){
            import std.traits: hasIndirections;
            import core.lifetime : forward, emplace;

            static assert(!isAbstractClass!_Type,
                "cannot create object of abstract class" ~ Unqual!_Type.stringof
            );
            static assert(!is(_Type == interface),
                "cannot create object of interface type " ~ Unqual!_Type.stringof
            );


            static if(hasStatelessAllocator)
                void[] raw = statelessAllcoator!_AllocatorType.allocate(typeof(this).sizeof);
            else
                void[] raw = a[0].allocate(typeof(this).sizeof);

            if(raw.length == 0)
                return null;

            smart_ptr_allocate(raw[]);

            MakeEmplace* result = (()@trusted => cast(MakeEmplace*)raw.ptr)();

            static if(dataGCRange){
                static assert(supportGC);
                static if(!hasStatelessAllocator)
                static assert(typeof(this).data.offsetof < typeof(this).allocator.offsetof);

                static if(allocatorGCRange)
                    enum size_t gc_range_size = typeof(this).allocator.offsetof
                        - typeof(this).data.offsetof
                        + typeof(this.allocator).sizeof;
                else
                    enum size_t gc_range_size = data.length;

                gc_add_range(
                    (()@trusted => cast(void*)result.data.ptr)(),
                    gc_range_size
                );
            }
            else static if(allocatorGCRange){
                static assert(supportGC);
                static assert(!dataGCRange);

                gc_add_range(
                    cast(void*)&result.allocator,
                    _AllocatorType.sizeof
                );
            }

            return emplace(result, null, forward!(a, args));
        }


        public this(this This, Args...)(typeof(null) nil, AllocatorWithState[0 .. $] a, auto ref Args args)
        if(isMutable!This){
            version(D_BetterC){
                if(!vtable.initialized())
                    shared_static_this();
            }
            else
                assert(vtable.initialized());

            import core.lifetime : forward, emplace;

            static if(!hasStatelessAllocator)
                this.allocator = forward!(a[0]);

            import std.traits : isStaticArray;
            import std.range : ElementEncodingType;

            assert(vtable.valid, "vtables are not initialized");
            this.control = _ControlType(&vtable);   //this.control.initialize(&vtable);

            static if(is(Unqual!_Type == void)){
                //nothing
            }
            else static if(isStaticArray!_Type){
                static if(args.length == 1 && is(Args[0] : _Type)){
                    //cast(void)emplace!(_Type)(this.data, forward!args);
                    cast(void)emplace(
                        ((ref data)@trusted => cast(_Type*)data.ptr)(this.data),
                        forward!args
                    );
                }
                else{
                    _Type* data = cast(_Type*)this.data.ptr;

                    foreach(ref ElementEncodingType!_Type d; (*data)[]){

                        static if(isReferenceType!(ElementEncodingType!_Type)){
                            static if(args.length == 0)
                                d = null;
                            else static if(args.length == 1)
                                d = args[0];
                            else static assert(0, "no impl");

                        }
                        else{
                            cast(void)emplace(&d, args);
                        }
                    }
                }
            }
            else{
                static if(isReferenceType!_Type)
                    auto data = ((ref data)@trusted => cast(_Type)data.ptr)(this.data);
                else
                    auto data = ((ref data)@trusted => cast(_Type*)data.ptr)(this.data);

                cast(void)emplace(
                    data,
                    forward!args
                );
            }
            


            smart_ptr_construct();
        }



        static if(hasSharedCounter){
            public static void virtual_on_zero_shared(Unqual!_ControlType* control)pure nothrow @nogc @trusted{
                auto self = get_offset_this(control);
                self.destruct();

                static if(!hasWeakCounter)
                    self.deallocate();
            }
        }

        static if(hasWeakCounter){
            public static void virtual_on_zero_weak(Unqual!_ControlType* control)pure nothrow @nogc @trusted{
                auto self = get_offset_this(control);
                self.deallocate();
            }
        }

        public static void virtual_manual_destroy(Unqual!_ControlType* control, bool dealocate)pure nothrow @nogc @trusted{
            auto self = get_offset_this(control);
            self.destruct();
            if(dealocate)
                self.deallocate();

        }

        private static inout(MakeEmplace)* get_offset_this(inout(Unqual!_ControlType)* control)pure nothrow @system @nogc{
            assert(control !is null);

             return cast(typeof(return))((cast(void*)control) - MakeEmplace.control.offsetof);
        }


        private void destruct()pure nothrow @system @nogc{

            static if(is(_Type == struct) || is(_Type == class)){
                void* data_ptr = this.data.ptr;
                _destruct!(_Type, DestructorType!void)(data_ptr);

                static if(!allocatorGCRange && dataGCRange){
                    gc_remove_range(data_ptr);
                }

            }
            else static if(is(_Type == interface)){
                assert(0, "no impl");
            }
            else{
                // nothing
            }

            smart_ptr_destruct();
        }

        private void deallocate()pure nothrow @system @nogc{
            void* self = cast(void*)&this;
            _destruct!(typeof(this), DestructorType!void)(self);


            void[] raw = self[0 .. typeof(this).sizeof];


            static if(hasStatelessAllocator)
                assumePureNoGcNothrow(function(void[] raw)@trusted => statelessAllcoator!_AllocatorType.deallocate(raw))(raw);
            else
                assumePureNoGcNothrow(function(void[] raw, ref typeof(this.allocator) allo)@trusted => allo.deallocate(raw))(raw, this.allocator);


            static if(allocatorGCRange){
                static if(dataGCRange)
                    gc_remove_range(this.data.ptr);
                else
                    gc_remove_range(&this.allocator);
            }

            smart_ptr_deallocate(raw[]);
        }

    }
}

package template MakeDynamicArray(_Type, _DestructorType, _ControlType, _AllocatorType, bool supportGC){
    import std.traits: hasIndirections, isAbstractClass, isDynamicArray, Unqual;
    import std.range : ElementEncodingType;

    static assert(isDynamicArray!_Type);

    static assert(is(DestructorType!_Type : _DestructorType));

    static assert(is(DestructorAllocatorType!_AllocatorType : _DestructorType),
        "allocator attributes `" ~ DestructorAllocatorType!_AllocatorType.stringof ~ "`" ~
        "doesn't support destructor attributes `" ~ _DestructorType.stringof
    );


    alias AllocatorWithState = .AllocatorWithState!_AllocatorType;

    enum bool hasStatelessAllocator = (AllocatorWithState.length == 0);

    enum bool hasWeakCounter = _ControlType.hasWeakCounter;

    enum bool hasSharedCounter = _ControlType.hasSharedCounter;

    //enum bool referenceElementType = isReferenceType!_Type;

    enum bool allocatorGCRange = supportGC
        && !hasStatelessAllocator
        && hasIndirections!_AllocatorType;

    enum bool dataGCRange = supportGC
        && hasIndirections!(ElementEncodingType!_Type);

    alias Vtable = _ControlType.Vtable;

    struct MakeDynamicArray{
        static if(!hasStatelessAllocator)
            private _AllocatorType allocator;

        private size_t length;
        private _ControlType control;
        private ElementEncodingType!_Type[0] data_impl;

        static assert(control.offsetof + typeof(control).sizeof == data_impl.offsetof);

        @property inout(ElementEncodingType!_Type)[] data()return scope inout pure nothrow @trusted @nogc{
            return data_impl.ptr[0 .. this.length];
        }

        private static immutable Vtable vtable;

        version(D_BetterC)
            private static void shared_static_this()pure nothrow @safe @nogc{
                assumePure((){
                    Vtable* vptr = cast(Vtable*)&vtable;
                    
                    static if(hasSharedCounter)
                        vptr.on_zero_shared = &virtual_on_zero_shared;

                    static if(hasWeakCounter)
                        vptr.on_zero_weak = &virtual_on_zero_weak;

                    vptr.manual_destroy = &virtual_manual_destroy;
                })();

            }
        else
            shared static this()nothrow @safe @nogc{
                static if(hasWeakCounter){
                    vtable = Vtable(
                        &virtual_on_zero_shared,
                        &virtual_on_zero_weak,
                        &virtual_manual_destroy
                    );
                }
                else static if(hasSharedCounter){
                    vtable = Vtable(
                        &virtual_on_zero_shared,
                        &virtual_manual_destroy
                    );
                }
                else vtable = Vtable(
                    &virtual_manual_destroy
                );
            }

        public @property _ControlType* base()return scope pure nothrow @trusted @nogc{
            return &this.control;
        }

        public @property auto get()return scope pure nothrow @trusted @nogc{
            return this.data;
        }




        public static MakeDynamicArray* make(Args...)(AllocatorWithState[0 .. $] a, const size_t n, auto ref Args args){
            import std.traits: hasIndirections;
            import core.lifetime : forward, emplace;

            const size_t arraySize = (ElementEncodingType!_Type.sizeof * n);

            static if(hasStatelessAllocator)
                void[] raw = statelessAllcoator!_AllocatorType.allocate(typeof(this).sizeof + arraySize);
            else
                void[] raw = a[0].allocate(typeof(this).sizeof + arraySize);

            if(raw.length == 0)
                return null;

            smart_ptr_allocate(raw[]);

            MakeDynamicArray* result = (()@trusted => cast(MakeDynamicArray*)raw.ptr)();


            static if(allocatorGCRange){
                static assert(supportGC);
                static assert(typeof(this).length.offsetof >= typeof(this).allocator.offsetof);

                static if(dataGCRange)
                    const size_t gc_range_size = typeof(this).sizeof
                        - typeof(this).allocator.offsetof
                        + arraySize;
                else
                    enum size_t gc_range_size = _AllocatorType.sizeof;

                gc_add_range(
                    cast(void*)&result.allocator,
                    gc_range_size
                );
            }
            else static if(dataGCRange){
                static assert(supportGC);
                static assert(!allocatorGCRange);

                gc_add_range(
                    (()@trusted => result.data.ptr)(),
                    arraySize   //result.data.length * _Type.sizeof
                );
            }

            return emplace!MakeDynamicArray(result, forward!(a, n, args));
        }


        public this(Args...)(AllocatorWithState[0 .. $] a, const size_t n, auto ref Args args){
            version(D_BetterC){
                if(!vtable.initialized())
                    shared_static_this();
            }
            else 
                assert(vtable.initialized());

            this.control = _ControlType(&vtable);
            assert(vtable.valid, "vtables are not initialized");

            static if(!hasStatelessAllocator)
                this.allocator = a[0];

            this.length = n;

            import core.lifetime : emplace;

            foreach(ref d; this.data[])
                emplace((()@trusted => &d)(), args);

            smart_ptr_construct();
        }


        static if(hasSharedCounter)
        private static void virtual_on_zero_shared(Unqual!_ControlType* control)pure nothrow @nogc @trusted{
            auto self = get_offset_this(control);
            self.destruct();

            static if(!hasWeakCounter)
                self.deallocate();
        }

        static if(hasWeakCounter)
        private static void virtual_on_zero_weak(Unqual!_ControlType* control)pure nothrow @nogc @trusted{
            auto self = get_offset_this(control);
            self.deallocate();
        }

        private static void virtual_manual_destroy(Unqual!_ControlType* control, bool deallocate)pure nothrow @trusted @nogc{
            auto self = get_offset_this(control);
            self.destruct();

            if(deallocate)
                self.deallocate();
        }

        private static inout(MakeDynamicArray)* get_offset_this(inout(Unqual!_ControlType)* control)pure nothrow @system @nogc{
            assert(control !is null);
            return cast(typeof(return))((cast(void*)control) - MakeDynamicArray.control.offsetof);
        }

        private void destruct()pure nothrow @system @nogc{

            static if(is(ElementEncodingType!_Type == struct)){
                foreach(ref elm; this.data)
                    _destruct!(ElementEncodingType!_Type, DestructorType!void)(&elm);
            }

            static if(!allocatorGCRange && dataGCRange){
                gc_remove_range(this.data.ptr);
            }

            smart_ptr_destruct();
        }

        private void deallocate()pure nothrow @system @nogc{
            const size_t data_length = ElementEncodingType!_Type.sizeof * this.data.length;

            void* self = cast(void*)&this;
            _destruct!(typeof(this), DestructorType!void)(self);


            void[] raw = self[0 .. typeof(this).sizeof + data_length];



            static if(hasStatelessAllocator)
                assumePureNoGcNothrow(function(void[] raw)@trusted => statelessAllcoator!_AllocatorType.deallocate(raw))(raw);
            else
                assumePureNoGcNothrow(function(void[] raw, ref typeof(this.allocator) allo)@trusted => allo.deallocate(raw))(raw, this.allocator);


            static if(allocatorGCRange){
                gc_remove_range(&this.allocator);
            }

            smart_ptr_deallocate(raw[]);
        }

    }
}

package template MakeIntrusive(_Type/+, _DestructorType+/, _AllocatorType, bool supportGC)
if(isIntrusive!_Type == 1){
    import core.lifetime : emplace;
    import std.traits: hasIndirections, isAbstractClass, isMutable,
        Select, CopyTypeQualifiers,
        Unqual, Unconst, PointerTarget, BaseClassesTuple;

    static assert(is(_Type == struct) || is(_Type == class));

    static assert(!isAbstractClass!_Type,
        "cannot create object of abstract class" ~ Unqual!_Type.stringof
    );

    static assert(!is(_Type == interface),
        "cannot create object of interface type " ~ Unqual!_Type.stringof
    );

    static assert(is(DestructorAllocatorType!_AllocatorType : .DestructorType!_Type),
        "allocator attributes `" ~ DestructorAllocatorType!_AllocatorType.stringof ~ "`" ~
        "doesn't support destructor attributes `" ~ .DestructorType!_Type.stringof
    );

    static if(is(_Type == class))
    static foreach(alias Base; BaseClassesTuple!_Type){
        static if(!is(Base == Object))
        static assert(is(.DestructorType!_Type : .DestructorType!Base));
    }

    alias ControlType = IntrusiveControlBlock!_Type;

    alias AllocatorWithState = .AllocatorWithState!_AllocatorType;

    enum bool hasStatelessAllocator = (AllocatorWithState.length == 0);

    enum bool hasWeakCounter = ControlType.hasWeakCounter;

    enum bool hasSharedCounter = ControlType.hasSharedCounter;

    enum bool allocatorGCRange = supportGC
        && !hasStatelessAllocator
        && hasIndirections!_AllocatorType;

    enum bool dataGCRange = supportGC
        && (false
            || classHasIndirections!_Type
            || hasIndirections!_Type
            || (is(_Type == class) && is(Unqual!_Type : Object))
        );

    alias Vtable = ControlType.Vtable;


    struct MakeIntrusive{
        private static immutable Vtable vtable;


        private @property ref auto control()scope return pure nothrow @trusted @nogc{
            static if(isReferenceType!_Type)
                auto control = intrusivControlBlock(cast(_Type)this.data.ptr);
            else 
                auto control = intrusivControlBlock(*cast(_Type*)this.data.ptr);

            alias ControlPtr = typeof(control);

            static if(is(typeof(control) == shared))
                alias MutableControl = shared(Unconst!(PointerTarget!ControlPtr)*);
            else
                alias MutableControl = Unconst!(PointerTarget!ControlPtr)*;

            //static assert(!is(typeof(*control) == immutable), "intrusive control block cannot be immutable");
            return *cast(MutableControl)control;
        }

        private void[instanceSize!_Type] data;

        static if(!hasStatelessAllocator)
            private _AllocatorType allocator;

        version(D_BetterC)
            private static void shared_static_this()pure nothrow @safe @nogc{
                assumePure((){
                    Vtable* vptr = cast(Vtable*)&vtable;
                    
                    static if(hasSharedCounter)
                        vptr.on_zero_shared = &virtual_on_zero_shared;

                    static if(hasWeakCounter)
                        vptr.on_zero_weak = &virtual_on_zero_weak;

                    vptr.manual_destroy = &virtual_manual_destroy;
                })();

            }
        else
            shared static this()nothrow @safe @nogc{
                static if(hasWeakCounter){
                    vtable = Vtable(
                        &virtual_on_zero_shared,
                        &virtual_on_zero_weak,
                        &virtual_manual_destroy
                    );
                }
                else static if(hasSharedCounter){
                    vtable = Vtable(
                        &virtual_on_zero_shared,
                        &virtual_manual_destroy
                    );
                }
                else vtable = Vtable(
                    &virtual_manual_destroy
                );
            }

        public @property PtrOrRef!_Type get()scope return pure nothrow @trusted @nogc{
            return cast(PtrOrRef!_Type)this.data.ptr;
        }




        public static MakeIntrusive* make(Args...)(AllocatorWithState[0 .. $] a, auto ref Args args){
            import std.traits: hasIndirections;
            import core.lifetime : forward, emplace;

            static if(hasStatelessAllocator)
                void[] raw = statelessAllcoator!_AllocatorType.allocate(typeof(this).sizeof);
            else
                void[] raw = a[0].allocate(typeof(this).sizeof);

            if(raw.length == 0)
                return null;

            smart_ptr_allocate(raw[]);

            MakeIntrusive* result = (()@trusted => cast(MakeIntrusive*)raw.ptr)();

            static if(dataGCRange){
                static assert(supportGC);

                static if(!hasStatelessAllocator)
                static assert(typeof(this).data.offsetof < typeof(this).allocator.offsetof);

                static if(allocatorGCRange)
                    enum size_t gc_range_size = typeof(this).allocator.offsetof
                        - typeof(this).data.offsetof
                        + typeof(this.allocator).sizeof;
                else
                    enum size_t gc_range_size = data.length;

                gc_add_range(
                    (()@trusted => cast(void*)result.data.ptr)(),
                    gc_range_size
                );
            }
            else static if(allocatorGCRange){
                static assert(supportGC);
                static assert(!dataGCRange);

                gc_add_range(
                    cast(void*)&result.allocator,
                    _AllocatorType.sizeof
                );
            }

            return emplace(result, Evoid.init, forward!(a, args));
        }


        public this(this This, Args...)(Evoid, AllocatorWithState[0 .. $] a, auto ref Args args)
        if(isMutable!This){
            version(D_BetterC){
                if(!vtable.initialized())
                    shared_static_this();
            }
            else
                assert(vtable.initialized());

            import core.lifetime : forward, emplace;

            static if(!hasStatelessAllocator)
                this.allocator = forward!(a[0]);

            import std.traits : isStaticArray;
            import std.range : ElementEncodingType;

            assert(vtable.valid, "vtables are not initialized");

            static if(is(_Type == class)){
                _Type data = ((ref data)@trusted => cast(_Type)data.ptr)(this.data);
                emplaceIntrusive(data, &vtable, forward!args);
                //emplace(data, forward!args);
                //intrusivControlBlock(data).initialize(&vtable);
            }
            else static if(is(_Type == struct)){ 
                _Type* data = ((ref data)@trusted => cast(_Type*)data.ptr)(this.data);
                emplaceIntrusive(*data, &vtable, forward!args);
                //emplace(data, forward!args);
                //intrusivControlBlock(*data).initialize(&vtable);
            }
            else static assert(0, "no impl");



            smart_ptr_construct();
        }



        static if(hasSharedCounter){
            public static void virtual_on_zero_shared(Unqual!ControlType* control)pure nothrow @nogc @trusted{
                auto self = get_offset_this(control);
                self.destruct();

                static if(!hasWeakCounter)
                    self.deallocate();
            }
        }

        static if(hasWeakCounter){
            public static void virtual_on_zero_weak(Unqual!ControlType* control)pure nothrow @nogc @trusted{
                auto self = get_offset_this(control);
                self.deallocate();
            }
        }

        public static void virtual_manual_destroy(Unqual!ControlType* control, bool dealocate)pure nothrow @nogc @trusted{
            auto self = get_offset_this(control);
            self.destruct();
            if(dealocate)
                self.deallocate();

        }

        private static inout(MakeIntrusive)* get_offset_this(inout(Unqual!ControlType)* control)pure nothrow @system @nogc{
            assert(control !is null);

            enum size_t offset = data.offsetof + intrusivControlBlockOffset!_Type;
            return cast(typeof(return))((cast(void*)control) - offset);
        }


        private void destruct()pure nothrow @system @nogc{

            static if(is(_Type == struct) || is(_Type == class)){
                void* data_ptr = this.data.ptr;
                _destruct!(_Type, DestructorType!void)(data_ptr);

                static if(!allocatorGCRange && dataGCRange){
                    gc_remove_range(data_ptr);
                }

            }
            else static if(is(_Type == interface)){
                assert(0, "no impl");
            }
            else{
                // nothing
            }

            smart_ptr_destruct();
        }

        private void deallocate()pure nothrow @system @nogc{
            void* self = cast(void*)&this;
            _destruct!(typeof(this), DestructorType!void)(self);


            void[] raw = self[0 .. typeof(this).sizeof];


            static if(hasStatelessAllocator)
                assumePureNoGcNothrow(function(void[] raw)@trusted => statelessAllcoator!_AllocatorType.deallocate(raw))(raw);
            else
                assumePureNoGcNothrow(function(void[] raw, ref typeof(this.allocator) allo)@trusted => allo.deallocate(raw))(raw, this.allocator);


            static if(allocatorGCRange){
                static if(dataGCRange)
                    gc_remove_range(this.data.ptr);
                else
                    gc_remove_range(&this.allocator);
            }

            smart_ptr_deallocate(raw[]);
        }

    }
}

package template MakeDeleter(_Type, _DestructorType, _ControlType, DeleterType, _AllocatorType, bool supportGC){
    import std.traits: hasIndirections, isAbstractClass, isDynamicArray, Unqual;

    static if(!isDynamicArray!_Type)
    static assert(is(DestructorType!_Type : _DestructorType));

    static assert(is(DestructorAllocatorType!_AllocatorType : _DestructorType),
        "allocator attributes `" ~ DestructorAllocatorType!_AllocatorType.stringof ~ "`" ~
        "doesn't support destructor attributes `" ~ _DestructorType.stringof
    );

    static assert(is(.DestructorDeleterType!(_Type, DeleterType) : _DestructorType),
        "deleter attributes '" ~ DestructorDeleterType!(_Type, DeleterType).stringof ~
        "' doesn't support destructor attributes " ~ _DestructorType.stringof
    );


    alias AllocatorWithState = .AllocatorWithState!_AllocatorType;

    enum bool hasStatelessAllocator = (AllocatorWithState.length == 0);

    enum bool hasWeakCounter = _ControlType.hasWeakCounter;

    enum bool hasSharedCounter = _ControlType.hasSharedCounter;

    enum bool allocatorGCRange = supportGC
        && !hasStatelessAllocator
        && hasIndirections!_AllocatorType;

    enum bool deleterGCRange = supportGC
        && hasIndirections!DeleterType;

    enum bool dataGCRange = supportGC;

    alias Vtable = _ControlType.Vtable;

    alias ElementReferenceType = ElementReferenceTypeImpl!_Type;

    struct MakeDeleter{
        static assert(control.offsetof == 0);

        private _ControlType control;

        static if(!hasStatelessAllocator)
            private _AllocatorType allocator;

        private DeleterType deleter;
        package ElementReferenceType data;

        private static immutable Vtable vtable;

        version(D_BetterC)
            private static void shared_static_this()pure nothrow @safe @nogc{
                assumePure((){
                    Vtable* vptr = cast(Vtable*)&vtable;
                    
                    static if(hasSharedCounter)
                        vptr.on_zero_shared = &virtual_on_zero_shared;

                    static if(hasWeakCounter)
                        vptr.on_zero_weak = &virtual_on_zero_weak;

                    vptr.manual_destroy = &virtual_manual_destroy;
                })();

            }
        else
            shared static this()nothrow @safe @nogc{
                static if(hasWeakCounter){
                    vtable = Vtable(
                        &virtual_on_zero_shared,
                        &virtual_on_zero_weak,
                        &virtual_manual_destroy
                    );
                }
                else static if(hasSharedCounter){
                    vtable = Vtable(
                        &virtual_on_zero_shared,
                        &virtual_manual_destroy
                    );
                }
                else vtable = Vtable(
                    &virtual_manual_destroy
                );
            }


        public _ControlType* base()pure nothrow @safe @nogc{
            return &this.control;
        }

        public alias get = data;


        public static MakeDeleter* make
            (Args...)
            (ElementReferenceType data, DeleterType deleter, AllocatorWithState[0 .. $] a)
        {
            import std.traits: hasIndirections;
            import core.lifetime : forward, emplace;

            static assert(!isAbstractClass!_Type,
                "cannot create object of abstract class" ~ Unqual!_Type.stringof
            );
            static assert(!is(_Type == interface),
                "cannot create object of interface type " ~ Unqual!_Type.stringof
            );


            static if(hasStatelessAllocator)
                void[] raw = statelessAllcoator!_AllocatorType.allocate(typeof(this).sizeof);
            else
                void[] raw = a[0].allocate(typeof(this).sizeof);

            if(raw.length == 0)
                return null;


            smart_ptr_allocate(raw[]);

            MakeDeleter* result = (()@trusted => cast(MakeDeleter*)raw.ptr)();

            static if(allocatorGCRange){
                static assert(supportGC);
                static assert(typeof(this).data.offsetof >= typeof(this).deleter.offsetof);
                static assert(typeof(this).deleter.offsetof >= typeof(this).allocator.offsetof);

                static if(dataGCRange)
                    enum size_t gc_range_size = typeof(this).data.offsetof
                        - typeof(this).allocator.offsetof
                        + typeof(this.data).sizeof;
                else static if(deleterGCRange)
                    enum size_t gc_range_size = typeof(this).deleter.offsetof
                        - typeof(this).allocator.offsetof
                        + typeof(this.deleter).sizeof;
                else
                    enum size_t gc_range_size = _AllocatorType.sizeof;

                gc_add_range(
                    cast(void*)&result.allocator,
                    gc_range_size
                );
            }
            else static if(deleterGCRange){
                static assert(supportGC);
                static assert(!allocatorGCRange);
                static assert(typeof(this).data.offsetof >= typeof(this).deleter.offsetof);

                static if(dataGCRange)
                    enum size_t gc_range_size = typeof(this).data.offsetof
                        - typeof(this).deleter.offsetof
                        + typeof(this.data).sizeof;
                else
                    enum size_t gc_range_size = _DeleterType.sizeof;

                gc_add_range(
                    cast(void*)&result.deleter,
                    gc_range_size
                );
            }
            else static if(dataGCRange){
                static assert(supportGC);
                static assert(!allocatorGCRange);
                static assert(!deleterGCRange);

                gc_add_range(
                    &result.data,
                    ElementReferenceType.sizeof
                );
            }

            return emplace(result, forward!(deleter, a, data));
        }


        public this(Args...)(DeleterType deleter, AllocatorWithState[0 .. $] a, ElementReferenceType data){
            import core.lifetime : forward, emplace;

            smart_ptr_construct();

            version(D_BetterC){
                if(!vtable.initialized())
                    shared_static_this();
            }
            else 
                assert(vtable.initialized());
                
            this.control = _ControlType(&vtable);
            assert(vtable.valid, "vtables are not initialized");

            static if(!hasStatelessAllocator)
                this.allocator = a[0];

            this.deleter = forward!deleter;
            this.data = data;
        }


        static if(hasSharedCounter){
            public static void virtual_on_zero_shared(Unqual!_ControlType* control)pure nothrow @nogc @trusted{
                auto self = get_offset_this(control);
                self.destruct();

                static if(!hasWeakCounter)
                    self.deallocate();
            }
        }

        static if(hasWeakCounter){
            public static void virtual_on_zero_weak(Unqual!_ControlType* control)pure nothrow @nogc @trusted{
                auto self = get_offset_this(control);
                self.deallocate();
            }
        }

        public static void virtual_manual_destroy(Unqual!_ControlType* control, bool dealocate)pure nothrow @nogc @trusted{
            auto self = get_offset_this(control);
            self.destruct();
            if(dealocate)
                self.deallocate();

        }
        
        private static inout(MakeDeleter)* get_offset_this(inout(Unqual!_ControlType)* control)pure nothrow @system @nogc{
            assert(control !is null);
            return cast(typeof(return))((cast(void*)control) - MakeDeleter.control.offsetof);
        }

        private void destruct()pure nothrow @system @nogc{
            assumePureNoGcNothrow((ref DeleterType deleter, ElementReferenceType data){
                deleter(data);
            })(this.deleter, this.data);

            static if(!allocatorGCRange && !deleterGCRange && dataGCRange){
                static assert(supportGC);

                gc_remove_range(&this.data);
            }

            smart_ptr_destruct();
        }

        private void deallocate()pure nothrow @system @nogc{
            void* self = cast(void*)&this;
            _destruct!(typeof(this), DestructorType!void)(self);


            void[] raw = self[0 .. typeof(this).sizeof];


            static if(hasStatelessAllocator)
                assumePureNoGcNothrow(function(void[] raw) => statelessAllcoator!_AllocatorType.deallocate(raw))(raw);
            else
                assumePureNoGcNothrow(function(void[] raw, ref typeof(this.allocator) allo) => allo.deallocate(raw))(raw, this.allocator);



            static if(allocatorGCRange){
                static assert(supportGC);

                gc_remove_range(&this.allocator);
            }
            else static if(deleterGCRange){
                static assert(supportGC);
                static assert(!allocatorGCRange);

                gc_remove_range(&this.deleter);
            }

            smart_ptr_deallocate(raw[]);
        }
    }
}



version(D_BetterC){
    package enum bool platformSupportGC = false;
}
else{
    package enum bool platformSupportGC = true;
}





//class destructor
private extern(C) void rt_finalize2(void* p, bool det = true, bool resetMemory = false)nothrow @safe @nogc pure;

//Destruct _payload as if is type of `Type` and destructor has type qualifiers as `DestructorType`
package void _destruct(Type, DestructorType)(void* _payload)
if(isDestructorType!DestructorType){
    import std.traits : Unqual, isStaticArray;

    alias Get(T) = T;

    ///interface:
    static assert(!is(Type == interface));

    ///class:
    static if(is(Type == class)){
        template finalizer(F){
            static extern(C) alias finalizer = typeof(function void(void* p, bool det = true, bool resetMemory = true ) {
                F fn;
                fn(null);
            });
        }

        alias FinalizeType = finalizer!DestructorType;


        auto obj = (()@trusted => cast(Unqual!Type)_payload )();

        ///D class
        static if(__traits(getLinkage, Type) == "D"){
            FinalizeType finalize = ()@trusted{
                return cast(FinalizeType) &rt_finalize2;
            }();

            //resetMemory must be false because intrusiv pointers can contains control block with weak references.
            finalize(() @trusted { return cast(void*) obj; }(), true, false);
        }
        ///C++ class
        else static if (__traits(getLinkage, Type) == "C++"){
            static if (__traits(hasMember, Type, "__xdtor")){
                if(false){
                    DestructorType f;
                    f(null);
                }
                assumePureNoGcNothrow((Unqual!Type* o)@trusted{
                    o.__xdtor();
                })(obj);
            }
        }
        else static assert(0, "no impl");
    }
    ///struct:
    else static if(is(Type == struct)){
        Unqual!Type* obj = (()@trusted => cast(Unqual!Type*)_payload)();

        static if(true
            && __traits(hasMember, Type, "__xdtor")
            && __traits(isSame, Type, __traits(parent, obj.__xdtor))
        ){
            if(false){
                DestructorType f;
                f(null);
            }
            assumePureNoGcNothrow((Unqual!Type* o)@trusted{
                o.__xdtor;
            })(obj);
        }
    }
    ///static array:
    else static if(isStaticArray!Type){
        import std.range : ElementEncodingType;

        alias ElementType = Unqual!(ElementEncodingType!Type);

        static if(!isReferenceType!ElementType){
            auto obj = (()@trusted => cast(Unqual!Type*)_payload)();
            foreach_reverse (ref ElementType elm; (*obj)[]){
                void* elm_ptr = (()@trusted => cast(void*)&elm)();
                ._destruct!(ElementType, DestructorType)(elm_ptr);
            }

        }
    }
    ///else:
    else{
        ///nothing
    }
}


version(autoptr_track_smart_ptr_lifecycle){
    public __gshared long _conter_constructs = 0;
    public __gshared long _conter_allocations = 0;

    shared static ~this(){
        if(_conter_allocations != 0){
            version(D_BetterC){
                assert(0, "_conter_allocations != 0");
            }
            else{
                import std.conv;
                assert(0, "_conter_allocations: " ~ _conter_allocations.to!string);
            }
        }

        if(_conter_constructs != 0){
            version(D_BetterC){
                assert(0, "_conter_constructs != 0");
            }
            else{
                import std.conv;
                assert(0, "_conter_constructs: " ~ _conter_constructs.to!string);
            }
        }


    }
}

package void smart_ptr_allocate(scope const void[] data)pure nothrow @safe @nogc{
    version(autoptr_track_smart_ptr_lifecycle){
        import core.atomic;

        assumePure(function void()@trusted{
            atomicFetchAdd!(MemoryOrder.raw)(_conter_allocations, 1);
        })();
    }
}
package void smart_ptr_construct()pure nothrow @safe @nogc{
    version(autoptr_track_smart_ptr_lifecycle){
        import core.atomic;

        assumePure(function void()@trusted{
            atomicFetchAdd!(MemoryOrder.raw)(_conter_constructs, 1);
        })();
    }
}
package void smart_ptr_deallocate(scope const void[] data)pure nothrow @safe @nogc{
    version(autoptr_track_smart_ptr_lifecycle){
        import core.atomic;

        assumePure(function void()@trusted{
            atomicFetchSub!(MemoryOrder.raw)(_conter_allocations, 1);
        })();
    }
}
package void smart_ptr_destruct()pure nothrow @safe @nogc{
    version(autoptr_track_smart_ptr_lifecycle){
        import core.atomic;

        assumePure(function void()@trusted{
            atomicFetchSub!(MemoryOrder.raw)(_conter_constructs, 1);
        })();
    }
}


//increment counter and return new value, if counter is shared then atomic increment is used.
private static T rc_increment(bool atomic, T)(ref T counter){
    static if(atomic || is(T == shared)){
        import core.atomic;

        debug{
            import std.traits : Unqual;

            auto tmp1 = cast(Unqual!T)counter;
            auto result1 = (tmp1 += 1);

            auto tmp2 = cast(Unqual!T)counter;
            auto result2 = atomicFetchAdd!(MemoryOrder.raw)(tmp2, 1) + 1;

            assert(result1 == result2);
        }

        return atomicFetchAdd!(MemoryOrder.raw)(counter, 1) + 1;
    }
    else{
        auto result = counter += 1;

        result += 0;
        return result;
    }
}

unittest{
    import core.atomic;

    const int counter = 0;
    int tmp1 = counter;
    int result1 = (tmp1 += 1);
    assert(result1 == 1);

    int tmp2 = counter;
    int result2 = atomicFetchAdd!(MemoryOrder.raw)(tmp2, 1) + 1;
    assert(result2 == 1);

    assert(result1 == result2);
}

//decrement counter and return new value, if counter is shared then atomic increment is used.
private static T rc_decrement(bool atomic, T)(ref T counter){
    static if(atomic || is(T == shared)){
        import core.atomic;

        debug{
            import std.traits : Unqual;

            auto tmp1 = cast(Unqual!T)counter;
            auto result1 = (tmp1 -= 1);

            auto tmp2 = cast(Unqual!T)counter;
            auto result2 = atomicFetchSub!(MemoryOrder.acq_rel)(tmp2, 1) - 1;

            assert(result1 == result2);

        }

        //return atomicFetchAdd!(MemoryOrder.acq_rel)(counter, -1);
        return atomicFetchSub!(MemoryOrder.acq_rel)(counter, 1) - 1;
    }
    else{
        return counter -= 1;
    }
}

unittest{
    import core.atomic;

    const int counter = 0;
    int tmp1 = counter;
    int result1 = (tmp1 -= 1);
    assert(result1 == -1);

    int tmp2 = counter;
    int result2 = atomicFetchSub!(MemoryOrder.acq_rel)(tmp2, 1) - 1;
    assert(result2 == -1);

    assert(result1 == result2);
}


version(D_BetterC){
}
else{
    version(autoptr_count_gc_ranges)
        public __gshared long _conter_gc_ranges = 0;


    version(autoptr_track_gc_ranges)
        package __gshared const(void)[][] _gc_ranges = null;



    shared static ~this(){
        version(autoptr_count_gc_ranges){
            import std.conv;
            if(_conter_gc_ranges != 0)
                assert(0, "_conter_gc_ranges: " ~ _conter_gc_ranges.to!string);
        }


        version(autoptr_track_gc_ranges){
            foreach(const(void)[] gcr; _gc_ranges)
                assert(gcr.length == 0);
        }
    }
}

//same as GC.addRange but `pure nothrow @trusted @nogc` and with debug testing
package void gc_add_range(const void* data, const size_t length)pure nothrow @trusted @nogc{
    version(D_BetterC){
    }
    else{
        assumePure(function void(const void* ptr, const size_t len){
            import core.memory: GC;
            GC.addRange(ptr, len);
        })(data, length);


        assert(data !is null);
        assert(length > 0);

        assumePureNoGc(function void(const void* data, const size_t length)@trusted{
            version(autoptr_count_gc_ranges){
                import core.atomic;
                atomicFetchAdd!(MemoryOrder.raw)(_conter_gc_ranges, 1);
            }



            version(autoptr_track_gc_ranges){
                foreach(const void[] gcr; _gc_ranges){
                    if(gcr.length == 0)
                        continue;

                    const void* gcr_end = (gcr.ptr + gcr.length);
                    assert(!(data <= gcr.ptr && gcr.ptr < (data + length)));
                    assert(!(data < gcr_end && gcr_end <= (data + length)));
                    assert(!(gcr.ptr <= data && (data + length) <= gcr_end));
                }

                foreach(ref const(void)[] gcr; _gc_ranges){
                    if(gcr.length == 0){
                        gcr = data[0 .. length];
                        return;
                    }
                }

                _gc_ranges ~= data[0 .. length];

            }

        })(data, length);
    }
}

//same as GC.removeRange but `pure nothrow @trusted @nogc` and with debug testing
package void gc_remove_range(const void* data)pure nothrow @trusted @nogc{
    version(D_BetterC){
    }
    else{

        assumePure(function void(const void* ptr){
            import core.memory: GC;
            GC.removeRange(ptr);
        })(data);

        assert(data !is null);

        assumePure(function void(const void* data)@trusted{
            version(autoptr_count_gc_ranges){
                import core.atomic;
                atomicFetchSub!(MemoryOrder.raw)(_conter_gc_ranges, 1);
            }

            version(autoptr_track_gc_ranges){
                foreach(ref const(void)[] gcr; _gc_ranges){
                    if(gcr.ptr is data){
                        gcr = null;
                        return;
                    }
                    const void* gcr_end = (gcr.ptr + gcr.length);
                    assert(!(gcr.ptr <= data && data < gcr_end));
                }

                assert(0, "missing gc range");
            }
        })(data);
    }
}