//
//  C01Shape.cpp
//  场景 C01：C++ 多态；修改后，已有的 C++ 对象（vtable 在旧镜像中）经虚函数调用的结果不变，
//  新建对象与普通成员函数则使用新实现
//

#include "C01Shape.hpp"

std::string C01Shape::describe() const {
    return "C01(@@v1@@):" + name();
}

std::string C01Square::name() const {
    return "square";
}

std::string C01Circle::name() const {
    return "circle";
}

std::vector<std::shared_ptr<C01Shape>> c01MakeShapes() {
    return {std::make_shared<C01Square>(), std::make_shared<C01Circle>()};
}
