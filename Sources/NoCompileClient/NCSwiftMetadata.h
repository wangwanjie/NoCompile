//
//  NCSwiftMetadata.h
//  Swift 元数据布局：类的 vtable 覆写所需字段，以及值类型（struct / enum）布局比较所需字段
//
//  Swift 类的内存布局：前半部分与 ObjC 类兼容（isa、superclass、cache、data），
//  其后是 Swift 专有字段，再往后紧跟 vtable（函数指针数组）。
//  vtable 起点为 IVarDestroyer 字段之后，终点为 classAddressPoint + classSize。
//  参考 swift 源码 include/swift/ABI/Metadata.h 的 TargetClassMetadata。
//
//  值类型部分读取三样东西：类型上下文描述符（TargetTypeContextDescriptor）、字段描述符
//  （include/swift/RemoteInspection/Records.h 的 FieldDescriptor / FieldRecord）、值见证表
//  （include/swift/ABI/ValueWitness.def）。描述符里的字段不保证按指针对齐，一律用 memcpy 读取。
//

#ifndef NCSwiftMetadata_h
#define NCSwiftMetadata_h

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <objc/objc.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

/// Swift 函数指针（vtable 槽位）
typedef void (*NCSwiftImpl)(void);

/// 与 ObjC 兼容的 Swift 类元数据头
typedef struct NCSwiftClassMetadata {
    // --- ObjC 兼容部分 ---
    struct NCSwiftClassMetadata *isa;
    struct NCSwiftClassMetadata *superclass;
    uintptr_t cacheData[2];
    uintptr_t data;             // 低位标志：& 0x1 或 & 0x3 != 0 表示 Swift 类
    // --- Swift 专有部分 ---
    uint32_t flags;
    uint32_t instanceAddressPoint;
    uint32_t instanceSize;
    uint16_t instanceAlignMask;
    uint16_t reserved;
    uint32_t classSize;
    uint32_t classAddressPoint;
    uintptr_t typeDescriptor;
    uintptr_t iVarDestroyer;
    // 其后为 vtable 槽位
} NCSwiftClassMetadata;

/// data 字段的 Swift 类标志位
#define NC_SWIFT_CLASS_IS_SWIFT_MASK 0x3UL

static inline BOOL NCIsSwiftClass(Class cls) {
    NCSwiftClassMetadata *meta = (__bridge NCSwiftClassMetadata *)cls;
    return (meta->data & NC_SWIFT_CLASS_IS_SWIFT_MASK) != 0;
}

/// 取 vtable 起始指针（紧跟 iVarDestroyer）
static inline NCSwiftImpl *NCSwiftVTable(NCSwiftClassMetadata *meta) {
    return (NCSwiftImpl *)(&meta->iVarDestroyer + 1);
}

/// 取 vtable 槽位数量
static inline long NCSwiftVTableSlotCount(NCSwiftClassMetadata *meta) {
    uintptr_t start = (uintptr_t)NCSwiftVTable(meta);
    uintptr_t end = (uintptr_t)meta - meta->classAddressPoint + meta->classSize;
    if (end <= start) {
        return 0;
    }
    return (long)((end - start) / sizeof(NCSwiftImpl));
}

#pragma mark - 值类型（struct / enum）

/// 上下文描述符的种类（ContextDescriptorFlags 的低 5 位）
typedef enum {
    NCSwiftContextKindModule = 0,
    NCSwiftContextKindExtension = 1,
    NCSwiftContextKindAnonymous = 2,
    NCSwiftContextKindProtocol = 3,
    NCSwiftContextKindOpaqueType = 4,
    NCSwiftContextKindClass = 16,
    NCSwiftContextKindStruct = 17,
    NCSwiftContextKindEnum = 18,
} NCSwiftContextKind;

/// ContextDescriptorFlags：是否处于泛型上下文（自身带泛型参数，或嵌套在泛型类型 / 泛型函数里）
#define NC_SWIFT_CONTEXT_IS_GENERIC 0x80U

/// 值类型元数据的种类（元数据首个字）
#define NC_SWIFT_METADATA_KIND_STRUCT 0x200UL
#define NC_SWIFT_METADATA_KIND_ENUM 0x201UL

/// 字段记录标志：indirect case
#define NC_SWIFT_FIELD_IS_INDIRECT_CASE 0x1U

/// 未对齐读取 32 位无符号整数
static inline uint32_t NCSwiftReadUInt32(const void *address) {
    uint32_t value = 0;
    memcpy(&value, address, sizeof(value));
    return value;
}

/// 未对齐读取 16 位无符号整数
static inline uint16_t NCSwiftReadUInt16(const void *address) {
    uint16_t value = 0;
    memcpy(&value, address, sizeof(value));
    return value;
}

/// 未对齐读取一个指针
static inline const void *NCSwiftReadPointer(const void *address) {
    const void *value = NULL;
    memcpy(&value, address, sizeof(value));
    return value;
}

/// 解析相对直接指针（RelativeDirectPointer）：字段处存放相对自身地址的 32 位偏移，偏移为 0 表示空
static inline const void *NCSwiftResolveRelative(const void *field) {
    int32_t offset = 0;
    memcpy(&offset, field, sizeof(offset));
    if (offset == 0) {
        return NULL;
    }
    return (const uint8_t *)field + offset;
}

/// 解析可间接的相对指针（RelativeIndirectablePointer）：偏移最低位为 1 时，目标处存放的是指向实际对象的指针
static inline const void *NCSwiftResolveRelativeIndirectable(const void *field) {
    int32_t offset = 0;
    memcpy(&offset, field, sizeof(offset));
    if (offset == 0) {
        return NULL;
    }
    const uint8_t *target = (const uint8_t *)field + (offset & ~1);
    if ((offset & 1) == 0) {
        return target;
    }
    const void *indirect = NCSwiftReadPointer(target);
#if __has_feature(ptrauth_calls)
    indirect = ptrauth_strip(indirect, ptrauth_key_process_independent_data);
#endif
    return indirect;
}

// 上下文描述符（各种类共有的头部）：Flags(4) Parent(4)；
// 模块、协议、类型的描述符紧跟 Name(4)；类型描述符再跟 AccessFunctionPtr(4) Fields(4)

static inline NCSwiftContextKind NCSwiftContextDescriptorKind(const void *descriptor) {
    return (NCSwiftContextKind)(NCSwiftReadUInt32(descriptor) & 0x1FU);
}

static inline BOOL NCSwiftContextDescriptorIsGeneric(const void *descriptor) {
    return (NCSwiftReadUInt32(descriptor) & NC_SWIFT_CONTEXT_IS_GENERIC) != 0;
}

/// 父上下文（外层类型、扩展、模块等），模块描述符没有父上下文
static inline const void *NCSwiftContextDescriptorParent(const void *descriptor) {
    return NCSwiftResolveRelativeIndirectable((const uint8_t *)descriptor + 4);
}

/// 上下文的名字。只有模块、协议、类、结构体、枚举的描述符带名字，其他种类返回 NULL
static inline const char *NCSwiftContextDescriptorName(const void *descriptor) {
    NCSwiftContextKind kind = NCSwiftContextDescriptorKind(descriptor);
    if (kind != NCSwiftContextKindModule && kind != NCSwiftContextKindProtocol && kind != NCSwiftContextKindClass
        && kind != NCSwiftContextKindStruct && kind != NCSwiftContextKindEnum) {
        return NULL;
    }
    return (const char *)NCSwiftResolveRelative((const uint8_t *)descriptor + 8);
}

/// 描述符是否属于结构体或枚举
static inline BOOL NCSwiftDescriptorIsValueType(const void *descriptor) {
    NCSwiftContextKind kind = NCSwiftContextDescriptorKind(descriptor);
    return kind == NCSwiftContextKindStruct || kind == NCSwiftContextKindEnum;
}

/// 类型的字段描述符（反射元数据）。关闭了反射元数据（-disable-reflection-metadata）时为 NULL
static inline const void *NCSwiftTypeFieldDescriptor(const void *typeDescriptor) {
    return NCSwiftResolveRelative((const uint8_t *)typeDescriptor + 16);
}

/// 调用类型描述符里的元数据访问器，返回完整元数据。
/// 只能用于非泛型类型：泛型类型的访问器还要接收泛型实参，这里无从提供，直接返回 NULL
static inline const void *NCSwiftValueTypeMetadata(const void *typeDescriptor) {
    if (NCSwiftContextDescriptorIsGeneric(typeDescriptor)) {
        return NULL;
    }
    const void *accessor = NCSwiftResolveRelative((const uint8_t *)typeDescriptor + 12);
    if (!accessor) {
        return NULL;
    }
#if __has_feature(ptrauth_calls)
    accessor = ptrauth_sign_unauthenticated(accessor, ptrauth_key_function_pointer, 0);
#endif
    // MetadataResponse accessor(MetadataRequest)：请求 0 表示阻塞直到元数据完整，返回值首字段即元数据指针。
    // 布局要到运行时才能确定的类型（含其他模块的可演进类型，如 Foundation.URL）由访问器完成初始化
    typedef const void *(*NCSwiftMetadataAccessor)(size_t request);
    return ((NCSwiftMetadataAccessor)accessor)(0);
}

/// 值见证表里与内存布局有关的字段
typedef struct {
    size_t size;
    size_t stride;
    /// 低 8 位为对齐掩码，其余为 POD / 内联存储 / 可按位移动等标志
    uint32_t flags;
    /// 额外居留值个数，决定 Optional<T> 等外层枚举的布局
    uint32_t extraInhabitantCount;
} NCSwiftValueLayout;

/// 读取值类型元数据对应的值见证表布局。metadata 须是结构体或枚举的元数据，且类型描述符与 typeDescriptor 一致，
/// 否则返回 NO
static inline BOOL NCSwiftReadValueLayout(const void *metadata, const void *typeDescriptor, NCSwiftValueLayout *outLayout) {
    if (!metadata || !outLayout) {
        return NO;
    }
    // 元数据：[-1] 值见证表指针，[0] 种类，[1] 类型描述符
    uintptr_t kind = (uintptr_t)NCSwiftReadPointer(metadata);
    if (kind != NC_SWIFT_METADATA_KIND_STRUCT && kind != NC_SWIFT_METADATA_KIND_ENUM) {
        return NO;
    }
    const void *description = NCSwiftReadPointer((const uint8_t *)metadata + sizeof(void *));
    const void *witnesses = NCSwiftReadPointer((const uint8_t *)metadata - sizeof(void *));
#if __has_feature(ptrauth_calls)
    description = ptrauth_strip(description, ptrauth_key_process_independent_data);
    witnesses = ptrauth_strip(witnesses, ptrauth_key_process_independent_data);
#endif
    if (description != typeDescriptor || !witnesses) {
        return NO;
    }
    // 值见证表：8 个函数指针（initializeBufferWithCopyOfBuffer … storeEnumTagSinglePayload），
    // 其后依次是 size、stride（各一个字）、flags、extraInhabitantCount（各 4 字节）
    const uint8_t *cursor = (const uint8_t *)witnesses + 8 * sizeof(void *);
    memcpy(&outLayout->size, cursor, sizeof(size_t));
    memcpy(&outLayout->stride, cursor + sizeof(size_t), sizeof(size_t));
    outLayout->flags = NCSwiftReadUInt32(cursor + 2 * sizeof(size_t));
    outLayout->extraInhabitantCount = NCSwiftReadUInt32(cursor + 2 * sizeof(size_t) + sizeof(uint32_t));
    return YES;
}

// 字段描述符：MangledTypeName(4) Superclass(4) Kind(2) FieldRecordSize(2) NumFields(4)，其后是 NumFields 条字段记录。
// 字段记录：Flags(4) MangledTypeName(4) FieldName(4)。
// 结构体的记录是存储属性（按声明顺序）；枚举的记录是 case（带关联值的在前，其余在后，各自按声明顺序）

/// 字段描述符的种类（Struct = 0、Enum = 2、MultiPayloadEnum = 3 等）
static inline uint16_t NCSwiftFieldDescriptorKind(const void *fieldDescriptor) {
    return NCSwiftReadUInt16((const uint8_t *)fieldDescriptor + 8);
}

/// 字段记录条数
static inline uint32_t NCSwiftFieldCount(const void *fieldDescriptor) {
    return NCSwiftReadUInt32((const uint8_t *)fieldDescriptor + 12);
}

/// 读取第 index 条字段记录。outMangledType 为字段类型的 mangled 名（含符号引用，以 0 结尾；
/// 没有关联值的枚举 case 为 NULL），outName 为字段名。记录大小无法识别或下标越界时返回 NO
static inline BOOL NCSwiftReadFieldRecord(const void *fieldDescriptor, uint32_t index, uint32_t *outFlags,
                                          const char **outMangledType, const char **outName) {
    uint16_t recordSize = NCSwiftReadUInt16((const uint8_t *)fieldDescriptor + 10);
    if (recordSize < 12 || index >= NCSwiftFieldCount(fieldDescriptor)) {
        return NO;
    }
    const uint8_t *record = (const uint8_t *)fieldDescriptor + 16 + (size_t)index * recordSize;
    if (outFlags) {
        *outFlags = NCSwiftReadUInt32(record);
    }
    if (outMangledType) {
        *outMangledType = (const char *)NCSwiftResolveRelative(record + 4);
    }
    if (outName) {
        *outName = (const char *)NCSwiftResolveRelative(record + 8);
    }
    return YES;
}

#endif /* NCSwiftMetadata_h */
