//
//  C03Error.hpp
//

#ifndef C03Error_hpp
#define C03Error_hpp

#include <stdexcept>
#include <string>

/// 自定义异常类型，由 C03Thrower.cpp 抛出，在 C03Catcher.mm 里捕获
class C03Error : public std::runtime_error {
public:
    explicit C03Error(const std::string &message) : std::runtime_error(message) {}
    virtual ~C03Error();
};

void c03Throw();

#endif /* C03Error_hpp */
