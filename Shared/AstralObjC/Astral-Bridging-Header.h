//
//  Astral-Bridging-Header.h
//  Astral_iOS target only.
//
//  Imports the Astral ObjC shims so Swift code sees their declarations.
//  Wired via the `SWIFT_OBJC_BRIDGING_HEADER` build setting on the
//  Astral_iOS target's Debug + Release configurations. The tvOS target
//  has no bridging header because there's no ObjC code on tvOS — every
//  shim here is iOS / Mac Catalyst only.
//
//  Adding new shims:
//    1. Drop the `.h` + `.m` into Shared/AstralObjC/
//    2. Add the `.m` to the Astral_iOS target's Compile Sources build phase
//    3. `#import "YourShim.h"` here
//

#ifndef Astral_Bridging_Header_h
#define Astral_Bridging_Header_h

#import "MPMediaItemArtworkShim.h"

#endif /* Astral_Bridging_Header_h */
