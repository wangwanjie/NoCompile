//
//  C03Thrower.cpp
//  场景 C03：C++ 异常跨文件抛出。修改本文件后，新镜像里抛出的 C03Error（typeinfo 来自新镜像）
//  要能被旧镜像里的 catch (const C03Error &) 捕获
//

#include "C03Error.hpp"

C03Error::~C03Error() {}

void c03Throw() {
    throw C03Error("C03(@@v1@@)");
}
