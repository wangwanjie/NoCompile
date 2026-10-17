//
//  C01Shape.hpp
//  场景 C01：带虚函数的 C++ 类层次（vtable、继承、多态）
//

#ifndef C01Shape_hpp
#define C01Shape_hpp

#include <string>
#include <vector>
#include <memory>

class C01Shape {
public:
    virtual ~C01Shape() {}
    virtual std::string name() const = 0;
    /// 非虚的公共方法，调用虚函数
    std::string describe() const;
};

class C01Square : public C01Shape {
public:
    std::string name() const override;
};

class C01Circle : public C01Shape {
public:
    std::string name() const override;
};

std::vector<std::shared_ptr<C01Shape>> c01MakeShapes();

#endif /* C01Shape_hpp */
