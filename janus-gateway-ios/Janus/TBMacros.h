//
//  TBMacros.h
//  janus-gateway-ios
//
//  Created by Nguyen Trong Bang on 28/3/18.
//  Copyright © 2018 MineWave. All rights reserved.
//

#ifndef TBMacros_h
#define TBMacros_h

#define weakify(var) __weak typeof(var) AHKWeak_##var = var;

#define strongify(var) \
_Pragma("clang diagnostic push") \
_Pragma("clang diagnostic ignored \"-Wshadow\"") \
__strong typeof(var) var = AHKWeak_##var; \
_Pragma("clang diagnostic pop")

#endif /* TBMacros_h */
