/* Implementation of class NSStackView
   Copyright (C) 2020 Free Software Foundation, Inc.
   
   By: Gregory John Casamento
   Date: 08-08-2020

   This file is part of the GNUstep Library.
   
   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.
   
   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.
   
   You should have received a copy of the GNU Lesser General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
   Boston, MA 02110 USA.
*/

#import "AppKit/NSStackView.h"
#import "GSFastEnumeration.h"

@implementation NSStackView

// Properties
- (void) setDelegate: (id<NSStackViewDelegate>)delegate
{
  _delegate = delegate;
}

- (id<NSStackViewDelegate>) delegate
{
  return _delegate;
}

- (void) setOrientation: (NSUserInterfaceLayoutOrientation)o
{
  _orientation = o;
}

- (NSUserInterfaceLayoutOrientation) orientation
{
  return _orientation;
}

- (void) setAlignment: (NSLayoutAttribute)alignment
{
  _alignment = alignment;
}

- (NSLayoutAttribute) alignment
{
  return _alignment;
}

- (void) setEdgeInsets: (NSEdgeInsets)insets
{
  _edgeInsets = insets;
}

- (NSEdgeInsets) edgeInsets
{
  return _edgeInsets;
}

- (void) setDistribution: (NSStackViewDistribution)d
{
  _distribution = d;
}

- (NSStackViewDistribution) distribution
{
  return _distribution;
}

- (void) setSpacing: (CGFloat)f
{
  _spacing = f;
}

- (CGFloat) spacing
{
  return _spacing;
}

- (void) setDetachesHiddenViews: (BOOL)f
{
  _detachesHiddenViews = f;
}

- (BOOL) detachesHiddenViews
{
  return _detachesHiddenViews;
}

- (void) setArrangedSubviews: (NSArray *)arrangedSubviews
{
  ASSIGN(_arrangedSubviews, arrangedSubviews);
}

- (NSArray *) arrangedSubviews
{
  return _arrangedSubviews;
}

- (void) setDetachedViews: (NSArray *)detachedViews
{
  ASSIGN(_detachedViews, detachedViews);
}

- (NSArray *) detachedViews
{
  return _detachedViews;
}

// Instance methods
// Manage views...
- (instancetype) initWithViews: (NSArray *)views
{
  self = [super init];
  if (self != nil)
    {
      _arrangedSubviews = [[NSMutableArray alloc] initWithArray: views];
      _detachedViews = [[NSMutableArray alloc] initWithCapacity: [views count]];
      ASSIGNCOPY(_views, views);
      _customSpacingMap = RETAIN([NSMapTable weakToWeakObjectsMapTable]);
      _gravityMap = RETAIN([NSMapTable weakToWeakObjectsMapTable]);
      _visiblePriorityMap = RETAIN([NSMapTable weakToWeakObjectsMapTable]);
      _clippingMap = RETAIN([NSMapTable strongToStrongObjectsMapTable]);
    }
  return self;
}

- (void) dealloc
{
  RELEASE(_arrangedSubviews);
  RELEASE(_detachedViews);
  RELEASE(_views);
  RELEASE(_customSpacingMap);
  RELEASE(_gravityMap);
  RELEASE(_visiblePriorityMap);
  RELEASE(_clippingMap);
  _delegate = nil;
  [super dealloc];
}

+ (instancetype) stackViewWithViews: (NSArray *)views
{
  return [[self alloc] initWithViews: views];
}

- (void) setCustomSpacing: (CGFloat)spacing afterView: (NSView *)v
{
  NSNumber *n = [NSNumber numberWithFloat: spacing];
  [_customSpacingMap setObject: n
                        forKey: v];
}

- (CGFloat) customSpacingAfterView: (NSView *)v
{
  return [[_customSpacingMap objectForKey: v] floatValue];
}

- (void) addArrangedSubview: (NSView *)v
{
  [_arrangedSubviews addObject: v];
}

- (void) insertArrangedSubview: (NSView *)v atIndex: (NSInteger)idx
{
  [_arrangedSubviews insertObject: v atIndex: idx];
}

- (void) removeArrangedSubview: (NSView *)v
{
  [_arrangedSubviews removeObject: v];
}

// Custom priorities
- (void)setVisibilityPriority: (NSStackViewVisibilityPriority)priority
                      forView: (NSView *)v
{
  NSNumber *n = [NSNumber numberWithInteger: priority];
  [_visiblePriorityMap setObject: n
                          forKey: v];
}

- (NSStackViewVisibilityPriority) visibilityPriorityForView: (NSView *)v
{
  NSNumber *n = [_visiblePriorityMap objectForKey: v];
  NSStackViewVisibilityPriority p = (NSStackViewVisibilityPriority)[n integerValue];
  return p;
}
 
- (NSLayoutPriority)clippingResistancePriorityForOrientation:(NSLayoutConstraintOrientation)orientation
{
  NSNumber *r = [_clippingMap objectForKey: orientation];
  return (NSLayoutPriority)[r integerValue];
}

- (void) setClippingResistancePriority: (NSLayoutPriority)clippingResistancePriority
                        forOrientation: (NSLayoutConstraintOrientation)orientation
{
  
}

- (NSLayoutPriority) huggingPriorityForOrientation: (NSLayoutConstraintOrientation)o
{
}

- (void) setHuggingPriority: (NSLayoutPriority)huggingPriority
             forOrientation: (NSLayoutConstraintOrientation)o
{
}

- (void) setHasEqualSpacing: (BOOL)f
{
  // deprecated
}

- (BOOL) hasEqualSpacing
{
  // deprecated
}

- (void)addView: (NSView *)view inGravity: (NSStackViewGravity)gravity
{
}

- (void)insertView: (NSView *)view atIndex: (NSUInteger)index inGravity: (NSStackViewGravity)gravity
{
}

- (void)removeView: (NSView *)view
{
}

- (NSArray *) viewsInGravity: (NSStackViewGravity)gravity
{
}

- (void)setViews: (NSArray *)views inGravity: (NSStackViewGravity)gravity
{
}

- (void) setViews: (NSArray *)views
{
  ASSIGN(_arrangedSubviews, views);
}

- (NSArray *) views
{
  return _arrangedSubviews;
}

// Encoding...
- (void) encodeWithCoder: (NSCoder *)coder
{
  [super encodeWithCoder: coder];
}

- (instancetype) initWithCoder: (NSCoder *)coder
{
  self = [super initWithCoder: coder];
  if (self != nil)
    {
      if ([coder allowsKeyedCoding])
        {
          if ([coder containsValueForKey: @"NSStackViewAlignment"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewBeginningContainer"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewDetachesHiddenViews"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewEdgeInsets.bottom"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewEdgeInsets.left"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewEdgeInsets.right"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewEdgeInsets.top"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewHasFlagViewHierarchy"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewHorizontalClippingResistance"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewHorizontalHugging"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewOrientation"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewSecondaryAlignment"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewSpacing"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewVerticalClippingResistance"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewVerticalHugging"])
            {
            }
          if ([coder containsValueForKey: @"NSStackViewdistribution"])
            {
            }        
        }
      else
        {
        }
    }
  return self;
}
  
@end

