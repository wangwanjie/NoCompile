//
//  C02Template.hpp
//  场景 C02：头文件里的 C++ 模板 + 内联函数。每个包含它的翻译单元都有一份实例化
//

#ifndef C02Template_hpp
#define C02Template_hpp

#include <string>
#include <map>

template <typename K, typename V>
class C02Cache {
public:
    void put(const K &key, const V &value) {
        map_[key] = value;
    }

    V get(const K &key, const V &fallback) const {
        auto it = map_.find(key);
        return it == map_.end() ? fallback : it->second;
    }

    static std::string tag() {
        return "C02(@@v1@@)";
    }

private:
    std::map<K, V> map_;
};

#endif /* C02Template_hpp */
