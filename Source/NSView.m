/** <title>NSView</title>

   <abstract>The view class which encapsulates all drawing functionality</abstract>

   Copyright (C) 1996 Free Software Foundation, Inc.

   Author: Scott Christley <scottc@net-community.com>
   Date: 1996
   Author: Ovidiu Predescu <ovidiu@net-community.com>
   Date: 1997
   Author: Felipe A. Rodriguez <far@ix.netcom.com>
   Date: August 1998
   Author: Richard Frith-Macdonald <richard@brainstorm.co.uk>
   Date: January 1999

   This file is part of the GNUstep GUI Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Library General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	 See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU Library General Public
   License along with this library; see the file COPYING.LIB.
   If not, write to the Free Software Foundation,
   51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
*/

#include "config.h"
#include <math.h>
#include <float.h>

#include <Foundation/NSString.h>
#include <Foundation/NSCalendarDate.h>
#include <Foundation/NSCoder.h>
#include <Foundation/NSKeyedArchiver.h>
#include <Foundation/NSDictionary.h>
#include <Foundation/NSThread.h>
#include <Foundation/NSLock.h>
#include <Foundation/NSArray.h>
#include <Foundation/NSNotification.h>
#include <Foundation/NSValue.h>
#include <Foundation/NSData.h>
#include <Foundation/NSDebug.h>
#include <Foundation/NSPathUtilities.h>
#include <Foundation/NSSet.h>

#include "AppKit/NSAffineTransform.h"
#include "AppKit/NSApplication.h"
#include "AppKit/NSDocumentController.h"
#include "AppKit/NSDocument.h"
#include "AppKit/NSClipView.h"
#include "AppKit/NSFont.h"
#include "AppKit/NSGraphics.h"
#include "AppKit/NSMenu.h"
#include "AppKit/NSPasteboard.h"
#include "AppKit/NSPrintInfo.h"
#include "AppKit/NSPrintOperation.h"
#include "AppKit/NSScrollView.h"
#include "AppKit/NSView.h"
#include "AppKit/NSWindow.h"
#include "AppKit/NSWorkspace.h"
#include "AppKit/PSOperators.h"
#include "GNUstepGUI/GSDisplayServer.h"
#include "GNUstepGUI/GSTrackingRect.h"
#include "GNUstepGUI/GSVersion.h"

/*
 * We need a fast array that can store objects without retain/release ...
 */
#define GSI_ARRAY_TYPES		GSUNION_OBJ
#define GSI_ARRAY_NO_RELEASE	1
#define GSI_ARRAY_NO_RETAIN	1

#ifdef GSIArray
#undef GSIArray
#endif
#include <GNUstepBase/GSIArray.h>

#define	nKV(O)	((GSIArray)(O->_nextKeyView))
#define	pKV(O)	((GSIArray)(O->_previousKeyView))

/* Variable tells this view and subviews that we're printing. Not really
   a class variable because we want it visible to subviews also
*/
NSView *viewIsPrinting = nil;

struct NSWindow_struct
{
  @defs(NSWindow)
};

/**
  <unit>
  <heading>NSView</heading>

  <p>NSView is an abstract class which provides facilities for drawing
  in a window and receiving events.  It is the superclass of many of
  the visual elements of the GUI.</p>

  <p>In order to display itself, a view must be placed in a window
  (represented by an NSWindow object).  Within the window is a
  hierarchy of NSViews, headed by the window's content view.  Every
  other view in a window is a descendant of this view.</p>

  <p>Subclasses can override -drawRect: in order to
  implement their appearance.  Other methods of NSView and NSResponder
  can also be overridden to handle user generated events.</p>

  </unit>
*/
  
@implementation NSView

/*
 * Class variables */
static Class	rectClass;
static Class	viewClass;

static NSAffineTransform	*flip = nil;

static NSNotificationCenter *nc = nil;

static SEL	preSel;
static SEL	invalidateSel;

static void	(*preImp)(NSAffineTransform*, SEL, NSAffineTransform*);
static void	(*invalidateImp)(NSView*, SEL);

/*
 *	Stuff to maintain a map table so we know what views are
 *	registered for drag and drop - we don't store the info in
 *	the view directly 'cot it would take up a pointer in each
 *	view and the vast majority of views wouldn't use it.
 *	Types are not registered/unregistered often enough for the
 *	performance of this mechanism to be an issue.
 */
static NSMapTable	*typesMap = 0;
static NSLock		*typesLock = nil;

/*
 * This is the only external interface to the drag types info.
 */
NSArray*
GSGetDragTypes(NSView *obj)
{
  NSArray	*t;

  [typesLock lock];
  t = (NSArray*)NSMapGet(typesMap, (void*)(gsaddr)obj);
  [typesLock unlock];
  return t;
}

static void
GSRemoveDragTypes(NSView* obj)
{
  [typesLock lock];
  NSMapRemove(typesMap, (void*)(gsaddr)obj);
  [typesLock unlock];
}

static NSArray*
GSSetDragTypes(NSView* obj, NSArray *types)
{
  unsigned	count = [types count];
  NSString	*strings[count];
  NSArray	*t;
  unsigned	i;

  /*
   * Make a new array with copies of the type strings so we don't get
   * them mutated by someone else.
   */
  [types getObjects: strings];
  for (i = 0; i < count; i++)
    {
      strings[i] = [strings[i] copy];
    }
  t = [NSArray arrayWithObjects: strings count: count];
  for (i = 0; i < count; i++)
    {
      RELEASE(strings[i]);
    }
  /*
   * Store it.
   */
  [typesLock lock];
  NSMapInsert(typesMap, (void*)(gsaddr)obj, (void*)(gsaddr)t);
  [typesLock unlock];
  return t;
}


/*
 *	Private methods.
 */


/*
 *	The [-_invalidateCoordinates] method marks the coordinate mapping
 *	matrices (matrixFromWindow and _matrixToWindow) and the cached visible
 *	rectangle as invalid.  It recursively invalidates the coordinates for
 *	all subviews as well.
 *	This method must be called whenever the size, shape or position of
 *	the view is changed in any way.
 */
- (void) _invalidateCoordinates
{
  if (_coordinates_valid == YES)
    {
      unsigned	count;

      _coordinates_valid = NO;
      if (_rFlags.valid_rects != 0)
	{
	  [_window invalidateCursorRectsForView: self];
	}
      if (_rFlags.has_subviews)
	{
	  count = [_sub_views count];
	  if (count > 0)
	    {
	      NSView*	array[count];
	      unsigned	i;

	      [_sub_views getObjects: array];
	      for (i = 0; i < count; i++)
		{
		  NSView	*sub = array[i];

		  if (sub->_coordinates_valid == YES)
		    {
		      (*invalidateImp)(sub, invalidateSel);
		    }
		}
	    }
	}
      [self releaseGState];
    }
}

/*
 *	The [-_matrixFromWindow] method returns a matrix that can be used to
 *	map coordinates in the windows coordinate system to coordinates in the
 *	views coordinate system.  It rebuilds the mapping matrices and
 *	visible rectangle cache if necessary.
 *	All coordinate transformations use this matrix.
 */
- (NSAffineTransform*) _matrixFromWindow
{
  if (_coordinates_valid == NO)
    {
      [self _rebuildCoordinates];
    }
  return _matrixFromWindow;
}

/*
 *	The [-_matrixToWindow] method returns a matrix that can be used to
 *	map coordinates in the views coordinate system to coordinates in the
 *	windows coordinate system.  It rebuilds the mapping matrices and
 *	visible rectangle cache if necessary.
 *	All coordinate transformations use this matrix.
 */
- (NSAffineTransform*) _matrixToWindow
{
  if (_coordinates_valid == NO)
    {
      [self _rebuildCoordinates];
    }
  return _matrixToWindow;
}

/*
 *	The [-_rebuildCoordinates] method rebuilds the coordinate mapping
 *	matrices (matrixFromWindow and _matrixToWindow) and the cached visible
 *	rectangle if they have been invalidated.
 */
- (void) _rebuildCoordinates
{
  if (_coordinates_valid == NO)
    {
      _coordinates_valid = YES;
      if (!_window)
	{
	  _visibleRect = NSZeroRect;
	  [_matrixToWindow makeIdentityMatrix];
	  [_matrixFromWindow makeIdentityMatrix];
	}
      if (!_super_view)
	{
	  _visibleRect = _bounds;
	  [_matrixToWindow makeIdentityMatrix];
	  [_matrixFromWindow makeIdentityMatrix];
	}
      else
	{
	  NSRect	superviewsVisibleRect;
	  BOOL		wasFlipped = _super_view->_rFlags.flipped_view;
	  NSAffineTransform	*pMatrix = [_super_view _matrixToWindow];

	  [_matrixToWindow takeMatrixFromTransform: pMatrix];
	  (*preImp)(_matrixToWindow, preSel, _frameMatrix);
	  if (_rFlags.flipped_view != wasFlipped)
	    {
	      /*
	       * The flipping process must result in a coordinate system that
	       * exactly overlays the original.	 To do that, we must translate
	       * the origin by the height of the view.
	       */
	      flip->matrix.tY = _frame.size.height;
	      (*preImp)(_matrixToWindow, preSel, flip);
	    }
	  (*preImp)(_matrixToWindow, preSel, _boundsMatrix);
	  [_matrixFromWindow takeMatrixFromTransform: _matrixToWindow];
	  [_matrixFromWindow invert];

	  superviewsVisibleRect = [self convertRect: [_super_view visibleRect]
					   fromView: _super_view];

	  _visibleRect = NSIntersectionRect(superviewsVisibleRect, _bounds);

	}
    }
}

- (void) _viewDidMoveToWindow
{
  [self viewDidMoveToWindow];
  if (_rFlags.has_subviews)
    {
      unsigned	count = [_sub_views count];

      if (count > 0)
	{
	  unsigned	i;
	  NSView	*array[count];

	  [_sub_views getObjects: array];
	  for (i = 0; i < count; ++i)
	    {
	      [array[i] _viewDidMoveToWindow];
	    }
	}
    }
}


/*
 * Class methods
 */
+ (void) initialize
{
  if (self == [NSView class])
    {
      Class	matrixClass = [NSAffineTransform class];
      NSAffineTransformStruct	ats = { 1, 0, 0, -1, 0, 1 };

      typesMap = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks,
                NSObjectMapValueCallBacks, 0);
      typesLock = [NSLock new];

      preSel = @selector(prependTransform:);
      invalidateSel = @selector(_invalidateCoordinates);

      preImp = (void (*)(NSAffineTransform*, SEL, NSAffineTransform*))
		[matrixClass instanceMethodForSelector: preSel];

      invalidateImp = (void (*)(NSView*, SEL))
		[self instanceMethodForSelector: invalidateSel];

      flip = [matrixClass new];
      [flip setTransformStruct: ats];

      nc = [NSNotificationCenter defaultCenter];

      viewClass = [NSView class];
      rectClass = [GSTrackingRect class];
      NSDebugLLog(@"NSView", @"Initialize NSView class\n");
      [self setVersion: 1];
    }
}

/**
 Return the view at the top of graphics contexts stack
 or nil if none is focused.
 */
+ (NSView*) focusView
{
  return [GSCurrentContext() focusView];
}

/*
 * Instance methods
 */
- (id) init
{
  return [self initWithFrame: NSZeroRect];
}

- (id) initWithFrame: (NSRect)frameRect
{
  [super init];

  if (frameRect.size.width < 0)
    {
      NSWarnMLog(@"given negative width", 0);
      frameRect.size.width = 0;
    }
  if (frameRect.size.height < 0)
    {
      NSWarnMLog(@"given negative height", 0);
      frameRect.size.height = 0;
    }
  _frame = frameRect;			// Set frame rectangle
  _bounds.origin = NSZeroPoint;		// Set bounds rectangle
  _bounds.size = _frame.size;

  _frameMatrix = [NSAffineTransform new];	// Map fromsuperview to frame
  _boundsMatrix = [NSAffineTransform new];	// Map fromsuperview to bounds
  _matrixToWindow = [NSAffineTransform new];	// Map to window coordinates
  _matrixFromWindow = [NSAffineTransform new];	// Map from window coordinates
  [_frameMatrix setFrameOrigin: _frame.origin];

  _sub_views = [NSMutableArray new];
  _tracking_rects = [NSMutableArray new];
  _cursor_rects = [NSMutableArray new];

  _super_view = nil;
  _window = nil;
  _is_rotated_from_base = NO;
  _is_rotated_or_scaled_from_base = NO;
  _rFlags.needs_display = YES;
  _post_frame_changes = NO;
  _autoresizes_subviews = YES;
  _autoresizingMask = NSViewNotSizable;
  _coordinates_valid = NO;
  _nextKeyView = 0;
  _previousKeyView = 0;

  _rFlags.flipped_view = [self isFlipped];

  return self;
}

- (void) dealloc
{
  NSView	*tmp;
  unsigned	count;

  while ([_sub_views count] > 0)
    {
      [[_sub_views lastObject] removeFromSuperviewWithoutNeedingDisplay];
    }

  /*
   * Remove self from view chain.  Try to mimic MacOS-X behavior ...
   * We send setNextKeyView: messages to all view for which we are the
   * next key view, setting their next key view to nil.
   *
   * First we do the obvious stuff using the standard methods.
   */
  [self setNextKeyView: nil];
  [[self previousKeyView] setNextKeyView: nil];

  /*
   * Now, we locate any remaining cases where a view has us as its next
   * view, and ask the view to change that.
   */
  if (pKV(self) != 0)
    {
      count = GSIArrayCount(pKV(self));
      while (count-- > 0)
	{
	  tmp = GSIArrayItemAtIndex(pKV(self), count).obj;
	  if ([tmp nextKeyView] == self)
	    {
	      [tmp setNextKeyView: nil];
	    }
	}
    }

  /*
   * Now we clean up the previous view array, in case subclasses have
   * overridden the default -setNextkeyView: method and broken things.
   * We also relase the memory we used.
   */
  if (pKV(self) != 0)
    {
      count = GSIArrayCount(pKV(self));
      while (count-- > 0)
	{
	  tmp = GSIArrayItemAtIndex(pKV(self), count).obj;
	  if (tmp != nil && nKV(tmp) != 0)
	    {
	      unsigned	otherCount = GSIArrayCount(nKV(tmp));
	
	      while (otherCount-- > 1)
		{
		  if (GSIArrayItemAtIndex(nKV(tmp), otherCount).obj == self)
		    {
		      GSIArrayRemoveItemAtIndex(nKV(tmp), otherCount);
		    }
		}
	      if (GSIArrayItemAtIndex(nKV(tmp), 0).obj == self)
		{
		  GSIArraySetItemAtIndex(nKV(tmp), (GSIArrayItem)nil, 0);
		}
	    }
	}
      GSIArrayClear(pKV(self));
      NSZoneFree(NSDefaultMallocZone(), pKV(self));
      _previousKeyView = 0;
    }

  /*
   * Now we clean up all views which have us as their previous view.
   * We also relase the memory we used.
   */
  if (nKV(self) != 0)
    {
      count = GSIArrayCount(nKV(self));
      while (count-- > 0)
	{
	  tmp = GSIArrayItemAtIndex(nKV(self), count).obj;
	  if (tmp != nil && pKV(tmp) != 0)
	    {
	      unsigned	otherCount = GSIArrayCount(pKV(tmp));
	
	      while (otherCount-- > 1)
		{
		  if (GSIArrayItemAtIndex(pKV(tmp), otherCount).obj == self)
		    {
		      GSIArrayRemoveItemAtIndex(pKV(tmp), otherCount);
		    }
		}
	      if (GSIArrayItemAtIndex(pKV(tmp), 0).obj == self)
		{
		  GSIArraySetItemAtIndex(pKV(tmp), (GSIArrayItem)nil, 0);
		}
	    }
	}
      GSIArrayClear(nKV(self));
      NSZoneFree(NSDefaultMallocZone(), nKV(self));
      _nextKeyView = 0;
    }

  RELEASE(_matrixToWindow);
  RELEASE(_matrixFromWindow);
  RELEASE(_frameMatrix);
  RELEASE(_boundsMatrix);
  TEST_RELEASE(_sub_views);
  TEST_RELEASE(_tracking_rects);
  TEST_RELEASE(_cursor_rects);
  [self unregisterDraggedTypes];
  [self releaseGState];

  [super dealloc];
}

/**
 * Adds aView as a subview of the receiver.
 */
- (void) addSubview: (NSView*)aView
{
  if (aView == nil)
    {
      [NSException raise: NSInvalidArgumentException
		  format: @"Adding a nil subview"];
    }
  if ([self isDescendantOf: aView])
    {
      [NSException raise: NSInvalidArgumentException
		format: @"addSubview: creates a loop in the views tree!"];
    }

  RETAIN(aView);
  [aView removeFromSuperview];
  if (aView->_coordinates_valid)
    {
      (*invalidateImp)(aView, invalidateSel);
    }
  [aView viewWillMoveToWindow: _window];
  [aView viewWillMoveToSuperview: self];
  [aView setNextResponder: self];
  [_sub_views addObject: aView];
  _rFlags.has_subviews = 1;
  [aView resetCursorRects];
  [aView setNeedsDisplay: YES];
  [aView _viewDidMoveToWindow];
  [aView viewDidMoveToSuperview];
  [self didAddSubview: aView];
  RELEASE(aView);
}

- (void) addSubview: (NSView*)aView
	 positioned: (NSWindowOrderingMode)place
	 relativeTo: (NSView*)otherView
{
  unsigned	index;

  if (aView == nil)
    {
      [NSException raise: NSInvalidArgumentException
		  format: @"Adding a nil subview"];
    }
  if ([self isDescendantOf: aView])
    {
      [NSException raise: NSInvalidArgumentException
		  format: @"addSubview:positioned:relativeTo: creates a "
	@"loop in the views tree!"];
    }

  if (aView == otherView)
    return;

  index = [_sub_views indexOfObjectIdenticalTo: otherView];
  if (index == NSNotFound)
    {
      if (place == NSWindowBelow)
	index = 0;
      else
	index = [_sub_views count];
    }
  else if (place != NSWindowBelow)
    {
      index += 1;
    }

  RETAIN(aView);
  [aView removeFromSuperview];
  if (aView->_coordinates_valid)
    {
      (*invalidateImp)(aView, invalidateSel);
    }
  [aView viewWillMoveToWindow: _window];
  [aView viewWillMoveToSuperview: self];
  [aView setNextResponder: self];
  [_sub_views insertObject: aView atIndex: index];
  _rFlags.has_subviews = 1;
  [aView resetCursorRects];
  [aView setNeedsDisplay: YES];
  [aView _viewDidMoveToWindow];
  [aView viewDidMoveToSuperview];
  [self didAddSubview: aView];
  RELEASE(aView);
}

/**
 * Returns self if aView is the receiver or aView is a subview of the receiver,
 * the ancestor view shared by aView and the receiver if any, or
 * aView if it is an ancestor of the receiver, otherwise returns nil.
 */
- (NSView*) ancestorSharedWithView: (NSView*)aView
{
  if (self == aView)
    return self;

  if ([self isDescendantOf: aView])
    return aView;

  if ([aView isDescendantOf: self])
    return self;

  /*
   * If neither are descendants of each other and either does not have a
   * superview then they cannot have a common ancestor
   */
  if (!_super_view)
    return nil;

  if (![aView superview])
    return nil;

  /* Find the common ancestor of superviews */
  return [_super_view ancestorSharedWithView: [aView superview]];
}

/**
 * Returns YES if aView is an ancestor of the receiver.
 */
- (BOOL) isDescendantOf: (NSView*)aView
{
  if (aView == self)
    return YES;

  if (!_super_view)
    return NO;

  if (_super_view == aView)
    return YES;

  return [_super_view isDescendantOf: aView];
}

- (NSView*) opaqueAncestor
{
  NSView	*next = _super_view;
  NSView	*current = self;

  while (next != nil)
    {
      if ([current isOpaque] == YES)
	{
	  break;
	}
      current = next;
      next = current->_super_view;
    }
  return current;
}

/**
 * Removes the receiver from its superviews list of subviews, by
 * invoking the superviews [-removeSubview:] method.
 */
- (void) removeFromSuperviewWithoutNeedingDisplay
{
  if (_super_view != nil)
    {
      [_super_view removeSubview: self];
    }
}

/**
  <p> Removes the receiver from its superviews list of subviews, by
  invoking the superviews -removeSubview: method, and marks the
  rectangle that the reciever occupied in the superview as needing
  redisplay.  </p>

  <p> This is dangerous to use during display, since it alters the
  rectangles needing display. In this case, you can use the
  -removeFromSuperviewWithoutNeedingDisplay method instead.</p> */
- (void) removeFromSuperview
{
  if (_super_view != nil)
    {
      [_super_view setNeedsDisplayInRect: _frame];
      [_super_view removeSubview: self];
    }
}

/**
  <p> Removes aSubview from the receivers list of subviews and from
  the responder chain.  </p>

  <p> Also invokes -viewWillMoveToWindow: on aView with a nil argument,
  to handle
  removal of aView (and recursively, its children) from its window -
  performing tidyup by invalidating cursor rects etc.  </p> 
*/
- (void) removeSubview: (NSView*)aView
{
  id view;
  /*
   * This must be first because it invokes -resignFirstResponder:, 
   * which assumes the view is still in the view hierarchy
   */
  for (view = [_window firstResponder];
    view != nil && [view respondsToSelector:@selector(superview)];
    view = [view superview])
    {
      if (view == aView)
	{      
	  [_window makeFirstResponder: _window];
	  break;
	}
    }
  [self willRemoveSubview: aView];
  aView->_super_view = nil;
  [aView viewWillMoveToWindow: nil];
  [aView viewWillMoveToSuperview: nil];
  [aView setNextResponder: nil];
  RETAIN(aView);
  [_sub_views removeObjectIdenticalTo: aView];
  [aView setNeedsDisplay: NO];
  [aView _viewDidMoveToWindow];
  [aView viewDidMoveToSuperview];
  RELEASE(aView);
  if ([_sub_views count] == 0)
    {
      _rFlags.has_subviews = 0;
    }
}

/**
 * Removes oldView, which should be a subview of the receiver, from the
 * receiver and places newView in its place. If newView is nil, just
 * removes oldView. If oldView is nil, just adds newView.
 */
- (void) replaceSubview: (NSView*)oldView with: (NSView*)newView
{
  if (newView == oldView)
    {
      return;
    }
  /*
   * NB. we implement the replacement in full rather than calling addSubview:
   * since classes like NSBox override these methods but expect to be able to
   * call [super replaceSubview:with:] safely.
   */
  if (oldView == nil)
    {
      /*
       * Strictly speaking, the docs say that if 'oldView' is not a subview
       * of the receiver then we do nothing - but here we add newView anyway.
       * So a replacement with no oldView is an addition.
       */
      RETAIN(newView);
      [newView removeFromSuperview];
      if (newView->_coordinates_valid)
	{
	  (*invalidateImp)(newView, invalidateSel);
	}
      [newView viewWillMoveToWindow: _window];
      [newView viewWillMoveToSuperview: self];
      [newView setNextResponder: self];
      [_sub_views addObject: newView];
      _rFlags.has_subviews = 1;
      [newView resetCursorRects];
      [newView setNeedsDisplay: YES];
      [newView _viewDidMoveToWindow];
      [newView viewDidMoveToSuperview];
      [self didAddSubview: newView];
      RELEASE(newView);
    }
  else if ([_sub_views indexOfObjectIdenticalTo: oldView] != NSNotFound)
    {
      if (newView == nil)
	{
	  /*
	   * If there is no new view to add - we just remove the old one.
	   * So a replacement with no newView is a removal.
	   */
	  [oldView removeFromSuperview];
	}
      else
	{
	  unsigned index;

	  /*
	   * Ok - the standard case - we remove the newView from wherever it
	   * was (which may have been in this view), locate the position of
	   * the oldView (which may have changed due to the removal of the
	   * newView), remove the oldView, and insert the newView in it's
	   * place.
	   */
	  RETAIN(newView);
	  [newView removeFromSuperview];
	  if (newView->_coordinates_valid)
	    {
	      (*invalidateImp)(newView, invalidateSel);
	    }
	  index = [_sub_views indexOfObjectIdenticalTo: oldView];
	  [oldView removeFromSuperview];
	  [newView viewWillMoveToWindow: _window];
	  [newView viewWillMoveToSuperview: self];
	  [newView setNextResponder: self];
  	  [_sub_views insertObject: newView
  		      atIndex: index];
	  _rFlags.has_subviews = 1;
	  [newView resetCursorRects];
	  [newView setNeedsDisplay: YES];
	  [newView _viewDidMoveToWindow];
	  [newView viewDidMoveToSuperview];
	  [self didAddSubview: newView];
	  RELEASE(newView);
	}
    }
}

- (void) sortSubviewsUsingFunction: (int (*)(id ,id ,void*))compare
			   context: (void*)context
{
  [_sub_views sortUsingFunction: compare context: context];
}

/**
 * Notifies the receiver that its superview is being changed to newSuper.
 */
- (void) viewWillMoveToSuperview: (NSView*)newSuper
{
  _super_view = newSuper;
}

/**
 * Notifies the receiver that it will now be a view of newWindow.
 * Note, this method is also used when removing a view from a window
 * (in which case, newWindow is nil) to let all the subviews know
 * that they have also been removed from the window.
 */
- (void) viewWillMoveToWindow: (NSWindow*)newWindow
{
  if (newWindow == _window)
    {
      return;
    }
  if (_coordinates_valid)
    {
      (*invalidateImp)(self, invalidateSel);
    }
  if (_rFlags.has_currects != 0)
    {
      [self discardCursorRects];
    }
  if (_rFlags.has_draginfo)
    {
      NSArray		*t = GSGetDragTypes(self);

      if (_window != nil)
	{
	  [GSDisplayServer removeDragTypes: t fromWindow: _window];
	}
      if (newWindow != nil)
	{
	  [GSDisplayServer addDragTypes: t toWindow: newWindow];
	}
    }

  _window = newWindow;

  if (_rFlags.has_subviews)
    {
      unsigned	count = [_sub_views count];

      if (count > 0)
	{
	  unsigned	i;
	  NSView	*array[count];

	  [_sub_views getObjects: array];
	  for (i = 0; i < count; ++i)
	    {
	      [array[i] viewWillMoveToWindow: newWindow];
	    }
	}
    }
}

- (void) didAddSubview: (NSView *)subview
{}

- (void) viewDidMoveToSuperview
{}

- (void) viewDidMoveToWindow
{}

- (void) willRemoveSubview: (NSView *)subview
{}

- (void) rotateByAngle: (float)angle
{
  if (_coordinates_valid)
    {
      (*invalidateImp)(self, invalidateSel);
    }
  [_boundsMatrix rotateByDegrees: angle];
  _is_rotated_from_base = _is_rotated_or_scaled_from_base = YES;

  if (_post_bounds_changes)
    {
      [nc postNotificationName: NSViewBoundsDidChangeNotification
			     object: self];
    }
}

- (void) _updateBoundsMatrix
{
  float sx;
  float sy;
  
  if (_bounds.size.width == 0)
    {
      if (_frame.size.width == 0)
	sx = 1;
      else
	sx = FLT_MAX;
    }
  else
    {
      sx = _frame.size.width / _bounds.size.width;
    }
  
  if (_bounds.size.height == 0)
    {
      if (_frame.size.height == 0)
	sy = 1;
      else
	sy = FLT_MAX;
    }
  else
    {
      sy = _frame.size.height / _bounds.size.height;
    }
  
  [_boundsMatrix scaleTo: sx : sy];
  if (sx != 1 || sy != 1)
    {
      _is_rotated_or_scaled_from_base = YES;
    }
}

- (void) setFrame: (NSRect)frameRect
{
  BOOL	changedOrigin = NO;
  BOOL	changedSize = NO;
  NSSize old_size = _frame.size;

  if (frameRect.size.width < 0)
    {
      NSWarnMLog(@"given negative width", 0);
      frameRect.size.width = 0;
    }
  if (frameRect.size.height < 0)
    {
      NSWarnMLog(@"given negative height", 0);
      frameRect.size.height = 0;
    }

  if (NSMinX(_frame) != NSMinX(frameRect) 
      || NSMinY(_frame) != NSMinY(frameRect))
    changedOrigin = YES;
  if (NSWidth(_frame) != NSWidth(frameRect) 
      || NSHeight(_frame) != NSHeight(frameRect))
    changedSize = YES;
  
  _frame = frameRect;
  /* FIXME: Touch bounds only if we are not scaled or rotated */
  _bounds.size = frameRect.size;
  

  if (changedOrigin)
    {
      [_frameMatrix setFrameOrigin: _frame.origin];
    }

  if (changedSize && _is_rotated_or_scaled_from_base)
    {
      [self _updateBoundsMatrix];
    }

  if (changedSize || changedOrigin)
    {
      if (_coordinates_valid)
	{
	  (*invalidateImp)(self, invalidateSel);
	}
      [self resizeSubviewsWithOldSize: old_size];
      if (_post_frame_changes)
	{
	  [nc postNotificationName: NSViewFrameDidChangeNotification
	      object: self];
	}
    }
}

- (void) setFrameOrigin: (NSPoint)newOrigin
{
  if (_coordinates_valid)
    {
      (*invalidateImp)(self, invalidateSel);
    }
  _frame.origin = newOrigin;
  [_frameMatrix setFrameOrigin: _frame.origin];

  if (_post_frame_changes)
    {
      [nc postNotificationName: NSViewFrameDidChangeNotification
	  object: self];
    }
}

- (void) setFrameSize: (NSSize)newSize
{
  NSSize old_size = _frame.size;

  if (newSize.width < 0)
    {
      NSWarnMLog(@"given negative width", 0);
      newSize.width = 0;
    }
  if (newSize.height < 0)
    {
      NSWarnMLog(@"given negative height", 0);
      newSize.height = 0;
    }
  if (_coordinates_valid)
    {
      (*invalidateImp)(self, invalidateSel);
    }

  if (_is_rotated_or_scaled_from_base)
    {
      float sx = _bounds.size.width  / _frame.size.width;
      float sy = _bounds.size.height / _frame.size.height;
      
      _frame.size = newSize;
      _bounds.size.width  = _frame.size.width  * sx;
      _bounds.size.height = _frame.size.height * sy;
    }
  else
    {
      _frame.size = _bounds.size = newSize;
    }

  [self resizeSubviewsWithOldSize: old_size];
  if (_post_frame_changes)
    {
      [nc postNotificationName: NSViewFrameDidChangeNotification
	  object: self];
    }
}

- (void) setFrameRotation: (float)angle
{
  if (_coordinates_valid)
    {
      (*invalidateImp)(self, invalidateSel);
    }
  [_frameMatrix setFrameRotation: angle];
  _is_rotated_from_base = _is_rotated_or_scaled_from_base = YES;

  if (_post_frame_changes)
    {
      [nc postNotificationName: NSViewFrameDidChangeNotification
	  object: self];
    }
}

- (BOOL) isRotatedFromBase
{
  if (_is_rotated_from_base)
    {
      return YES;
    }
  else if (_super_view)
    {
      return [_super_view isRotatedFromBase];
    }
  else
    {
      return NO;
    }
}

- (BOOL) isRotatedOrScaledFromBase
{
  if (_is_rotated_or_scaled_from_base)
    {
      return YES;
    }
  else if (_super_view)
    {
      return [_super_view isRotatedOrScaledFromBase];
    }
  else
    {
      return NO;
    }
}

- (void) scaleUnitSquareToSize: (NSSize)newSize
{
  if (newSize.width < 0)
    {
      NSWarnMLog(@"given negative width", 0);
      newSize.width = 0;
    }
  if (newSize.height < 0)
    {
      NSWarnMLog(@"given negative height", 0);
      newSize.height = 0;
    }
  if (_coordinates_valid)
    {
      (*invalidateImp)(self, invalidateSel);
    }
  _bounds.size.width  = _bounds.size.width  / newSize.width;
  _bounds.size.height = _bounds.size.height / newSize.height;

  _is_rotated_or_scaled_from_base = YES;
  
  [self _updateBoundsMatrix];

  if (_post_bounds_changes)
    {
      [nc postNotificationName: NSViewBoundsDidChangeNotification
	  object: self];
    }
}

- (void) setBounds: (NSRect)aRect
{
  if (aRect.size.width < 0)
    {
      NSWarnMLog(@"given negative width", 0);
      aRect.size.width = 0;
    }
  if (aRect.size.height < 0)
    {
      NSWarnMLog(@"given negative height", 0);
      aRect.size.height = 0;
    }
  if (_coordinates_valid)
    {
      (*invalidateImp)(self, invalidateSel);
    }
  _bounds = aRect;
  [_boundsMatrix
    setFrameOrigin: NSMakePoint(-_bounds.origin.x, -_bounds.origin.y)];
  [self _updateBoundsMatrix];

  if (_post_bounds_changes)
    {
      [nc postNotificationName: NSViewBoundsDidChangeNotification
	  object: self];
    }
}

- (void) setBoundsOrigin: (NSPoint)newOrigin
{
  _bounds.origin = newOrigin;

  if (_coordinates_valid)
    {
      (*invalidateImp)(self, invalidateSel);
    }
  [_boundsMatrix setFrameOrigin: NSMakePoint(-newOrigin.x, -newOrigin.y)];

  if (_post_bounds_changes)
    {
      [nc postNotificationName: NSViewBoundsDidChangeNotification
	  object: self];
    }
}

- (void) setBoundsSize: (NSSize)newSize
{
  if (newSize.width < 0)
    {
      NSWarnMLog(@"given negative width", 0);
      newSize.width = 0;
    }
  if (newSize.height < 0)
    {
      NSWarnMLog(@"given negative height", 0);
      newSize.height = 0;
    }
  if (_coordinates_valid)
    {
      (*invalidateImp)(self, invalidateSel);
    }

  _bounds.size = newSize;
  [self _updateBoundsMatrix];

  if (_post_bounds_changes)
    {
      [nc postNotificationName: NSViewBoundsDidChangeNotification
	  object: self];
    }
}

- (void) setBoundsRotation: (float)angle
{
  if (_coordinates_valid)
    {
      (*invalidateImp)(self, invalidateSel);
    }
  [_boundsMatrix setFrameRotation: angle];
  _is_rotated_from_base = _is_rotated_or_scaled_from_base = YES;

  if (_post_bounds_changes)
    {
      [nc postNotificationName: NSViewBoundsDidChangeNotification
	  object: self];
    }
}

- (void) translateOriginToPoint: (NSPoint)point
{
  if (_coordinates_valid)
    {
      (*invalidateImp)(self, invalidateSel);
    }
  [_boundsMatrix translateToPoint: point];

  if (_post_bounds_changes)
    {
      [nc postNotificationName: NSViewBoundsDidChangeNotification
	  object: self];
    }
}

- (NSRect) centerScanRect: (NSRect)aRect
{
  NSAffineTransform	*matrix;

  /*
   *	Hmm - we assume that the windows coordinate system is centered on the
   *	pixels of the screen - this may not be correct of course.
   *	Plus - this is all pretty meaningless is we are not in a window!
   */
  matrix = [self _matrixToWindow];
  aRect.origin = [matrix pointInMatrixSpace: aRect.origin];
  aRect.size = [matrix sizeInMatrixSpace: aRect.size];

  aRect.origin.x = floor(aRect.origin.x);
  aRect.origin.y = floor(aRect.origin.y);
  aRect.size.width = floor(aRect.size.width);
  aRect.size.height = floor(aRect.size.height);

  matrix = [self _matrixFromWindow];
  aRect.origin = [matrix pointInMatrixSpace: aRect.origin];
  aRect.size = [matrix sizeInMatrixSpace: aRect.size];

  return aRect;
}

- (NSPoint) convertPoint: (NSPoint)aPoint fromView: (NSView*)aView
{
  NSPoint	new;
  NSAffineTransform	*matrix;

  if (!aView)
    aView = [[_window contentView] superview];
  if (aView == self || aView == nil)
    return aPoint;
  NSAssert(_window == [aView window], NSInvalidArgumentException);

  matrix = [aView _matrixToWindow];
  new = [matrix pointInMatrixSpace: aPoint];

  if (_coordinates_valid)
    {
      matrix = _matrixFromWindow;
    }
  else
    {
      matrix = [self _matrixFromWindow];
    }
  new = [matrix pointInMatrixSpace: new];

  return new;
}

- (NSPoint) convertPoint: (NSPoint)aPoint toView: (NSView*)aView
{
  NSPoint	new;
  NSAffineTransform	*matrix;

  if (aView == nil)
    {
      aView = [[_window contentView] superview];
    }
  if (aView == self || aView == nil)
    {
      return aPoint;
    }
  NSAssert(_window == [aView window], NSInvalidArgumentException);

  if (_coordinates_valid)
    {
      matrix = _matrixToWindow;
    }
  else
    {
      matrix = [self _matrixToWindow];
    }
  new = [matrix pointInMatrixSpace: aPoint];  
  matrix = [aView _matrixFromWindow];
  new = [matrix pointInMatrixSpace: new];

  return new;
}


/* Helper for -convertRect:fromView: and -convertRect:toView:. */
static NSRect convert_rect_using_matrices(NSRect aRect, NSAffineTransform *matrix1,
					  NSAffineTransform *matrix2)
{
  NSRect r;
  NSPoint p[4], min, max;
  int i;

  for (i = 0; i < 4; i++)
    p[i] = aRect.origin;
  p[1].x += aRect.size.width;
  p[2].y += aRect.size.height;
  p[3].x += aRect.size.width;
  p[3].y += aRect.size.height;

  for (i = 0; i < 4; i++)
    p[i] = [matrix1 pointInMatrixSpace: p[i]];

  min = max = p[0] = [matrix2 pointInMatrixSpace: p[0]];
  for (i = 1; i < 4; i++)
    {
      p[i] = [matrix2 pointInMatrixSpace: p[i]];
      min.x = MIN(min.x, p[i].x);
      min.y = MIN(min.y, p[i].y);
      max.x = MAX(max.x, p[i].x);
      max.y = MAX(max.y, p[i].y);
    }

  r.origin = min;
  r.size.width = max.x - min.x;
  r.size.height = max.y - min.y;

  return r;
}

/**
 * Converts aRect from the coordinate system of aView to the coordinate
 * system of the receiver, ie. returns the bounding rectangle in the
 * receiver of aRect in aView.
 * <br />
 * aView and the receiver must be in the same window. If aView is nil,
 * converts from the receiver's window's coordinate system.
 */
- (NSRect) convertRect: (NSRect)aRect fromView: (NSView*)aView
{
  NSAffineTransform *matrix1, *matrix2;

  if (aView == nil)
    {
      aView = [[_window contentView] superview];
    }
  if (aView == self || aView == nil)
    {
      return aRect;
    }
  NSAssert(_window == [aView window], NSInvalidArgumentException);

  matrix1 = [aView _matrixToWindow];

  if (_coordinates_valid)
    {
      matrix2 = _matrixFromWindow;
    }
  else
    {
      matrix2 = [self _matrixFromWindow];
    }

  return convert_rect_using_matrices(aRect, matrix1, matrix2);
}

/**
 * Converts aRect from the coordinate system of the receiver to the
 * coordinate system of aView, ie. returns the bounding rectangle in
 * aView of aRect in the receiver.
 * <br />
 * aView and the receiver must be in the same window. If aView is nil,
 * converts to the receiver's window's coordinate system.
 */
- (NSRect) convertRect: (NSRect)aRect toView: (NSView*)aView
{
  NSAffineTransform *matrix1, *matrix2;

  if (aView == nil)
    {
      aView = [[_window contentView] superview];
    }
  if (aView == self || aView == nil)
    {
      return aRect;
    }
  NSAssert(_window == [aView window], NSInvalidArgumentException);

  if (_coordinates_valid)
    {
      matrix1 = _matrixToWindow;
    }
  else
    {
      matrix1 = [self _matrixToWindow];
    }

  matrix2 = [aView _matrixFromWindow];

  return convert_rect_using_matrices(aRect, matrix1, matrix2);
}

- (NSSize) convertSize: (NSSize)aSize fromView: (NSView*)aView
{
  NSSize		new;
  NSAffineTransform	*matrix;

  if (aView == nil)
    {
      aView = [[_window contentView] superview];
    }
  if (aView == self || aView == nil)
    {
      return aSize;
    }
  NSAssert(_window == [aView window], NSInvalidArgumentException);
  matrix = [aView _matrixToWindow];
  new = [matrix sizeInMatrixSpace: aSize];

  if (_coordinates_valid)
    {
      matrix = _matrixFromWindow;
    }
  else
    {
      matrix = [self _matrixFromWindow];
    }
  new = [matrix sizeInMatrixSpace: new];

  return new;
}

- (NSSize) convertSize: (NSSize)aSize toView: (NSView*)aView
{
  NSSize		new;
  NSAffineTransform	*matrix;

  if (aView == nil)
    {
      aView = [[_window contentView] superview];
    }
  if (aView == self || aView == nil)
    {
      return aSize;
    }
  NSAssert(_window == [aView window], NSInvalidArgumentException);
  if (_coordinates_valid)
    {
      matrix = _matrixToWindow;
    }
  else
    {
      matrix = [self _matrixToWindow];
    }
  new = [matrix sizeInMatrixSpace: aSize];

  matrix = [aView _matrixFromWindow];
  new = [matrix sizeInMatrixSpace: new];

  return new;
}

- (void) setPostsFrameChangedNotifications: (BOOL)flag
{
  _post_frame_changes = flag;
}

- (void) setPostsBoundsChangedNotifications: (BOOL)flag
{
  _post_bounds_changes = flag;
}

/*
 * resize subviews only if we are supposed to and we have never been rotated
 */
- (void) resizeSubviewsWithOldSize: (NSSize)oldSize
{
  if (_rFlags.has_subviews)
    {
      id e, o;

      if (_autoresizes_subviews == NO || _is_rotated_from_base == YES)
	return;

      e = [_sub_views objectEnumerator];
      o = [e nextObject];
      while (o)
	{
	  [o resizeWithOldSuperviewSize: oldSize];
	  o = [e nextObject];
	}
    }
}

- (void) resizeWithOldSuperviewSize: (NSSize)oldSize
{
  int		options = 0;
  NSSize	superViewFrameSize;
  NSRect        newFrame = _frame;
  BOOL		changedOrigin = NO;
  BOOL		changedSize = NO;

  if (_autoresizingMask == NSViewNotSizable)
    return;

  superViewFrameSize = NSMakeSize(0,0);
  if (_super_view)
    superViewFrameSize = [_super_view frame].size;

  /*
   * determine if and how the X axis can be resized
   */
  if (_autoresizingMask & NSViewWidthSizable)
    options++;

  if (_autoresizingMask & NSViewMinXMargin)
    options++;

  if (_autoresizingMask & NSViewMaxXMargin)
    options++;

  /*
   * adjust the X axis if any X options are set in the mask
   */
  if (options > 0)
    {
      float change = superViewFrameSize.width - oldSize.width;
      float changePerOption = change / options;

      if (_autoresizingMask & NSViewWidthSizable)
	{ 
          newFrame.size.width += changePerOption;
          changedSize = YES;
	}
      if (_autoresizingMask & NSViewMinXMargin)
	{
	  newFrame.origin.x += changePerOption;
	  changedOrigin = YES;
	}
    }

  /*
   * determine if and how the Y axis can be resized
   */
  options = 0;
  if (_autoresizingMask & NSViewHeightSizable)
    options++;

  if (_autoresizingMask & NSViewMinYMargin)
    options++;

  if (_autoresizingMask & NSViewMaxYMargin)
    options++;

  /*
   * adjust the Y axis if any Y options are set in the mask
   */
  if (options > 0)
    {
      float change = superViewFrameSize.height - oldSize.height;
      float changePerOption = change / options;
      
      if (_autoresizingMask & NSViewHeightSizable)
	{
          newFrame.size.height += changePerOption;
	  changedSize = YES;
	}
      if (_autoresizingMask & (NSViewMaxYMargin | NSViewMinYMargin))
	{
	  if (_super_view && _super_view->_rFlags.flipped_view == YES)
	    {
	      if (_autoresizingMask & NSViewMaxYMargin)
		{
		  newFrame.origin.y += changePerOption;
		  changedOrigin = YES;
		}
	    }
	  else
	    {
	      if (_autoresizingMask & NSViewMinYMargin)
		{
		  newFrame.origin.y += changePerOption;
		  changedOrigin = YES;
		}
	    }
	}
    }
  [self setFrame: newFrame];
}

/**
  <p> Tell the view to maintain a private gstate object which
  encapsulates all the information about drawing, such as coordinate
  transforms, line widths, etc. If you do not invoke this method, a
  gstate object is constructed each time the view is lockFocused.
  Allocating a private gstate may improve the performance of views
  that are focused a lot and have a lot of customized drawing
  parameters.  </p> 

  <p> View subclasses should override the
  setUpGstate method to set these custom parameters.
  </p> 
*/
- (void) allocateGState
{
  _allocate_gstate = 1;
  _renew_gstate = 1;
}

/**
  Frees the gstate object, if there is one. Note that the next time
  the view is lockFocused, the gstate will be allocated again.  */
- (void) releaseGState
{
  if (_allocate_gstate && _gstate)
    GSUndefineGState(GSCurrentContext(), _gstate);
  _gstate = 0;
  /* Note that the next time we lock focus, we'll realloc a gstate (if
     _allocate_gstate). This seems to make sense, and also allows us
     to call this method each time we invalidate the coordinates */
}

/**
  Returns an identifier that represents the view's gstate object,
  which is used to encapsulate drawing information about the view.
  Most of the time a gstate object is created from scratch when the
  view is focused, so if the view is not currently focused or
  allocateGState has not been called, then this method will */
- (int) gState
{
  return _gstate;
}

/** 
  Invalidates the view's gstate object so it will be set up again
  using setUpGState the next time the view is focused.  */
- (void) renewGState
{
  _renew_gstate = 1;
}

/* Overridden by subclasses to setup custom gstate */
- (void) setUpGState
{
}

- (void) lockFocusInRect: (NSRect)rect
{
  NSGraphicsContext *ctxt = GSCurrentContext();
  NSRect wrect;
  int window_gstate = 0;

  if (viewIsPrinting == nil)
    {
      NSAssert(_window != nil, NSInternalInconsistencyException);
      /* Check for deferred window */
      if ((window_gstate = [_window gState]) == 0)
	{
	  return;
	}
    }

  [ctxt lockFocusView: self inRect: rect];
  wrect = [self convertRect: rect toView: nil];
  NSDebugLLog(@"NSView", @"-lockFocusInRect: %@\n"
	      @"\t for view %@ in window %p (%@)\n"
	      @"\t frame %@, flip %d",
	      NSStringFromRect(wrect),
	      self, _window, NSStringFromRect([_window frame]),
	      NSStringFromRect(_frame),_rFlags.flipped_view);
  if (viewIsPrinting == nil)
    {
      struct NSWindow_struct *window_t = (struct NSWindow_struct *)_window;
      [window_t->_rectsBeingDrawn addObject: [NSValue valueWithRect: wrect]];
    }

  /* Make sure we don't modify superview's gstate */
  DPSgsave(ctxt);

  if (viewIsPrinting != nil)
    {
      if (viewIsPrinting == self)
	{
	  /* Make sure coordinates are valid, then fake that we don't have
	     a superview so we get printed correctly */
	  [self _matrixToWindow];
	  [_matrixToWindow makeIdentityMatrix];
	}
      else
	{
	  [[self _matrixToWindow] concat];
	}
      DPSrectclip(ctxt, NSMinX(rect), NSMinY(rect), 
		      NSWidth(rect), NSHeight(rect));

      /* Allow subclases to make other modifications */
      [self setUpGState];
    }
  else
    {
      NSAffineTransform *matrix;
      matrix = [self _matrixToWindow];

      if (_gstate)
	{
	  DPSsetgstate(ctxt, _gstate);
	  if (_renew_gstate)
	    {
	      [self setUpGState];
	    }
	  _renew_gstate = 0;
	  DPSgsave(ctxt);
	}
      else
	{

	  DPSsetgstate(ctxt, window_gstate);
	  DPSgsave(ctxt);
	  [matrix concat];

	  /* Allow subclases to make other modifications */
	  [self setUpGState];
	  _renew_gstate = 0;
	  if (_allocate_gstate)
	    {
	      _gstate = GSDefineGState(ctxt);
	      /* Balance the previous gsave and install our own gstate */
	      DPSgrestore(ctxt);
	      DPSsetgstate(ctxt, _gstate);
	      DPSgsave(ctxt);
	    }

	}
      /* Clip to the visible rectangle - which will never be greater
       * than the bounds of the view.  This prevents drawing outside
       * our bounds
       */
      DPSrectclip(ctxt, NSMinX(rect), NSMinY(rect),
			NSWidth(rect), NSHeight(rect));
    }
  /* This is obsolete. Backends shouldn't depend on this */
  GSWSetViewIsFlipped(ctxt, _rFlags.flipped_view);
}

- (void) unlockFocusNeedsFlush: (BOOL)flush
{
  NSGraphicsContext *ctxt = GSCurrentContext();

  NSDebugLLog(@"NSView_details", @"-unlockFocusNeedsFlush: %i for view %@\n",
	      flush, self);

  if (viewIsPrinting == nil)
    {
      NSAssert(_window != nil, NSInternalInconsistencyException);
      /* Check for deferred window */
      if ([_window gState] == 0)
	return;

      /* Restore our original gstate */
      DPSgrestore(ctxt);
    }

  /* Restore state of nesting lockFocus */
  DPSgrestore(ctxt);
  if (!_allocate_gstate)
    _gstate = 0;

  if (viewIsPrinting == nil)
    {
      NSRect        rect;
      struct	NSWindow_struct *window_t;
      window_t = (struct NSWindow_struct *)_window;
      if (flush)
	{
	  rect = [[window_t->_rectsBeingDrawn lastObject] rectValue];
	  window_t->_rectNeedingFlush =
	    NSUnionRect(window_t->_rectNeedingFlush, rect);
	  window_t->_f.needs_flush = YES;
	}
      [window_t->_rectsBeingDrawn removeLastObject];
    }
  [ctxt unlockFocusView: self needsFlush: YES ];
}

- (void) lockFocus
{
  [self lockFocusInRect: [self visibleRect]];
}

- (void) unlockFocus
{
  [self unlockFocusNeedsFlush: YES];
}

- (BOOL) lockFocusIfCanDraw
{
  if ([self canDraw])
    {
      [self lockFocus];
      return YES;
    }
  else
    {
      return NO;
    }
}

- (BOOL) canDraw
{			// not implemented per OS spec FIX ME
  if (((viewIsPrinting != nil) && [self isDescendantOf: viewIsPrinting]) || 
      ((_window != nil) && ([_window windowNumber] != 0) && 
       ![self isHiddenOrHasHiddenAncestor]))
    {
      return YES;
    }
  else
    {
      return NO;
    }
}

- (void) display
{
  [self displayRect: [self visibleRect]];
}

- (void) displayIfNeeded
{
  if (_rFlags.needs_display == YES)
    {
      if ([self isOpaque] == YES)
	{
	  [self displayIfNeededIgnoringOpacity];
	}
      else
	{
	  NSView	*firstOpaque = [self opaqueAncestor];
	  NSRect	rect;

	  if (_coordinates_valid == NO)
	    {
	      [self _rebuildCoordinates];
	    }
	  rect = NSIntersectionRect(_invalidRect, _visibleRect);
	  rect = [firstOpaque convertRect: rect  fromView: self];
	  if (NSIsEmptyRect(rect) == NO)
	    {
	      [firstOpaque displayIfNeededInRectIgnoringOpacity: rect];
	    }
	  /*
	   * If we still need display after displaying the invalid rectangle,
	   * display any subviews that need display.
	   */ 
	  if (_rFlags.needs_display == YES)
	    {
	      NSEnumerator	*enumerator = [_sub_views objectEnumerator];
	      NSView		*sub;

	      while ((sub = [enumerator nextObject]) != nil)
		{
		  if (sub->_rFlags.needs_display)
		    {
		      [sub displayIfNeededIgnoringOpacity];
		    }
		}
	      _rFlags.needs_display = NO;
	    }
	}
    }
}

- (void) displayIfNeededIgnoringOpacity
{
  if (_rFlags.needs_display == YES)
    {
      NSRect	rect;

      if (_coordinates_valid == NO)
	{
	  [self _rebuildCoordinates];
	}
      rect = NSIntersectionRect(_invalidRect, _visibleRect);
      if (NSIsEmptyRect(rect) == NO)
	{
	  [self displayIfNeededInRectIgnoringOpacity: rect];
	}
      /*
       * If we still need display after displaying the invalid rectangle,
       * display any subviews that need display.
       */ 
      if (_rFlags.needs_display == YES)
	{
	  NSEnumerator	*enumerator = [_sub_views objectEnumerator];
	  NSView	*sub;

	  while ((sub = [enumerator nextObject]) != nil)
	    {
	      if (sub->_rFlags.needs_display)
		{
		  [sub displayIfNeededIgnoringOpacity];
		}
	    }
	  _rFlags.needs_display = NO;
	}
    }
}

- (void) displayIfNeededInRect: (NSRect)aRect
{
  if (_rFlags.needs_display == NO)
    {
      if ([self isOpaque] == YES)
	{
	  [self displayIfNeededInRectIgnoringOpacity: aRect];
	}
      else
	{
	  NSView	*firstOpaque = [self opaqueAncestor];
	  NSRect	rect;

	  rect = [firstOpaque convertRect: aRect fromView: self];
	  [firstOpaque displayIfNeededInRectIgnoringOpacity: rect];
	}
    }
}

- (void) displayIfNeededInRectIgnoringOpacity: (NSRect)aRect
{
  if (![self canDraw])
    {
      return;
    }
  if (_rFlags.needs_display == YES)
    {
      BOOL	subviewNeedsDisplay = NO;
      NSRect	neededRect;
      NSRect	redrawRect;

      [_window disableFlushWindow];
      if (_coordinates_valid == NO)
	{
	  [self _rebuildCoordinates];
	}
      aRect = NSIntersectionRect(aRect, _visibleRect);
      redrawRect = NSIntersectionRect(aRect, _invalidRect);
      neededRect = NSIntersectionRect(_visibleRect, _invalidRect);

      if (NSIsEmptyRect(redrawRect) == NO)
	{
	  [self lockFocusInRect: redrawRect];
	  [self drawRect: redrawRect];
	  [self unlockFocusNeedsFlush: YES];
	}
      if (_rFlags.has_subviews == YES)
	{
	  unsigned	count = [_sub_views count];

	  if (count > 0)
	    {
	      NSView	*array[count];
	      unsigned	i;

	      [_sub_views getObjects: array];

	      for (i = 0; i < count; i++)
		{
		  NSRect	isect;
		  NSView	*subview = array[i];
		  NSRect	subviewFrame = subview->_frame;
		  BOOL		intersectCalculated = NO;

		  if ([subview->_frameMatrix isRotated])
		    {
		      [subview->_frameMatrix boundingRectFor: subviewFrame
						     result: &subviewFrame];
		    }

		  /*
		   * Having drawn ourself into the rect, we must make sure that
		   * subviews overlapping the area are redrawn.
		   */
		  isect = NSIntersectionRect(redrawRect, subviewFrame);
		  if (NSIsEmptyRect(isect) == NO)
		    {
		      isect = [subview convertRect: isect
					  fromView: self];
		      intersectCalculated = YES;
		      /*
		       * hack the ivars of the subview directly for speed.
		       */
		      subview->_rFlags.needs_display = YES;
		      subview->_invalidRect = NSUnionRect(subview->_invalidRect,
			    isect);
		    }

		  if (subview->_rFlags.needs_display == YES)
		    {
		      if (intersectCalculated == NO
			|| NSEqualRects(aRect, redrawRect) == NO)
			{
			  isect = NSIntersectionRect(aRect, subviewFrame);
			  isect = [subview convertRect: isect
					      fromView: self];
			}
		      [subview displayIfNeededInRectIgnoringOpacity: isect];
		      if (subview->_rFlags.needs_display == YES)
			{
			  subviewNeedsDisplay = YES;
			}
		    }
		}
	    }
	}

      /*
       * If the rect we displayed contains the _invalidRect or _visibleRect
       * then we can empty _invalidRect.
       * If all subviews have been fully displayed, we can also turn off the
       * 'needs_display' flag.
       */
      if (NSEqualRects(aRect, NSUnionRect(neededRect, aRect)) == YES)
	{
	  _invalidRect = NSZeroRect;
	  _rFlags.needs_display = subviewNeedsDisplay;
	}
      if (_rFlags.needs_display == YES
	&& NSEqualRects(aRect, NSUnionRect(_visibleRect, aRect)) == YES)
	{
	  _rFlags.needs_display = NO;
	}
      [_window enableFlushWindow];
      [_window flushWindowIfNeeded];
    }
}

/**
 * Causes the area of the view specified by aRect to be displayed.
 * This is done by moving up the view hierarchy until an opaque view
 * is found, then asking that view to update the appropriate area.
 */
- (void) displayRect: (NSRect)aRect
{
  if ([self isOpaque] == YES)
    {
      [self displayRectIgnoringOpacity: aRect];
    }
  else
    {
      NSView *firstOpaque = [self opaqueAncestor];

      aRect = [firstOpaque convertRect: aRect fromView: self];
      [firstOpaque displayRectIgnoringOpacity: aRect];
    }
}

- (void) displayRectIgnoringOpacity: (NSRect)aRect
{
  BOOL		subviewNeedsDisplay = NO;
  NSRect	neededRect;

  if (![self canDraw])
    {
      return;
    }

  [_window disableFlushWindow];
  if (_coordinates_valid == NO)
    {
      [self _rebuildCoordinates];
    }
  aRect = NSIntersectionRect(aRect, _visibleRect);
  neededRect = NSIntersectionRect(_invalidRect, _visibleRect);

  if (NSIsEmptyRect(aRect) == NO)
    {
      /*
       * Now we draw this view.
       */
      [self lockFocusInRect: aRect];
      [self drawRect: aRect];
    }

  if (_rFlags.has_subviews == YES)
    {
      unsigned		count = [_sub_views count];

      if (count > 0)
	{
	  NSView	*array[count];
	  unsigned	i;

	  [_sub_views getObjects: array];

	  for (i = 0; i < count; ++i)
	    {
	      NSView	*subview = array[i];
	      NSRect	subviewFrame = subview->_frame;
	      NSRect	isect;
	      BOOL	intersectCalculated = NO;

	      if ([subview->_frameMatrix isRotated] == YES)
		[subview->_frameMatrix boundingRectFor: subviewFrame
					       result: &subviewFrame];

	      /*
	       * Having drawn ourself into the rect, we must make sure that
	       * subviews overlapping the area are redrawn.
	       */
	      isect = NSIntersectionRect(aRect, subviewFrame);
	      if (NSIsEmptyRect(isect) == NO)
		{
		  isect = [subview convertRect: isect
				      fromView: self];
		  intersectCalculated = YES;
		  /*
		   * hack the ivars of the subview directly for speed.
		   */
		  subview->_rFlags.needs_display = YES;
		  subview->_invalidRect = NSUnionRect(subview->_invalidRect,
			isect);
		}

	      if (subview->_rFlags.needs_display == YES)
		{
		  if (intersectCalculated == NO)
		    {
		      isect = [subview convertRect: isect
					  fromView: self];
		    }
		  [subview displayIfNeededInRectIgnoringOpacity: isect];
		  if (subview->_rFlags.needs_display == YES)
		    {
		      subviewNeedsDisplay = YES;
		    }
		}
	    }
	}
    }

  if (NSIsEmptyRect(aRect) == NO)
    {
      [self unlockFocusNeedsFlush: YES];
    }

  /*
   * If the rect we displayed contains the _invalidRect or _visibleRect
   * then we can empty _invalidRect.  If all subviews have been
   * fully displayed, we can also turn off the 'needs_display' flag.
   */
  if (NSEqualRects(aRect, NSUnionRect(neededRect, aRect)) == YES)
    {
      _invalidRect = NSZeroRect;
      _rFlags.needs_display = subviewNeedsDisplay;
    }
  if (_rFlags.needs_display == YES
    && NSEqualRects(aRect, NSUnionRect(_visibleRect, aRect)) == YES)
    {
      _rFlags.needs_display = NO;
    }
  [_window enableFlushWindow];
  [_window flushWindowIfNeeded];
}

/**
  This method is invoked to handle drawing inside the view.  The
  default NSView's implementation does nothing; subclasses might
  override it to draw something inside the view.  Since NSView's
  implementation is guaranteed to be empty, you should not call
  super's implementation when you override it in subclasses.
  drawRect: is invoked when the focus has already been locked on the
  view; you can use arbitrary postscript functions in drawRect: to
  draw inside your view; the coordinate system in which you draw is
  the view's own coordinate system (this means for example that you
  should refer to the rectangle covered by the view using its bounds,
  and not its frame).  The argument of drawRect: is the rectangle
  which needs to be redrawn.  In a lossy implementation, you can
  ignore the argument and redraw the whole view; if you are aiming at
  performance, you may want to redraw only what is inside the
  rectangle which needs to be redrawn; this usually improves drawing
  performance considerably.  */
- (void) drawRect: (NSRect)rect
{}

- (NSRect) visibleRect
{
  if (_coordinates_valid == NO)
    {
      [self _rebuildCoordinates];
    }
  return _visibleRect;
}

- (BOOL) wantsDefaultClipping
{
  return YES;
}

- (BOOL) needsToDrawRect: (NSRect)aRect
{
  NSRect rect;
  struct NSWindow_struct *window_t;

  window_t = (struct NSWindow_struct *)_window;
  rect = [[window_t->_rectsBeingDrawn lastObject] rectValue];
  return NSIntersectsRect(rect, aRect);
}

- (void) getRectsBeingDrawn: (const NSRect **)rects count: (int *)count
{
  // FIXME
  if (count != NULL)
    {
      *count = 0;
    }
}

extern NSThread *GSAppKitThread; /* TODO */

/*
For -setNeedsDisplay*, the real work is done in the ..._real methods, and
the actual public method simply calls it, but makes sure that the call is
in the main thread.
*/

- (void) _setNeedsDisplay_real: (NSNumber *)n
{
  BOOL flag = [n boolValue];

  if (flag)
    {
      [self setNeedsDisplayInRect: _bounds];
    }
  else
    {
      _rFlags.needs_display = NO;
      _invalidRect = NSZeroRect;
    }
}

/**
 * As an exception to the general rules for threads and gui, this
 * method is thread-safe and may be called from any thread. Display
 * will always be done in the main thread. (Note that other methods are
 * in general not thread-safe; if you want to access other properties of
 * views from multiple threads, you need to provide the synchronization.)
 */
- (void) setNeedsDisplay: (BOOL)flag
{
  NSNumber *n = [[NSNumber alloc] initWithBool: flag];
  if (GSCurrentThread() != GSAppKitThread)
    {
      [self performSelectorOnMainThread: @selector(_setNeedsDisplay_real:)
	withObject: n
	waitUntilDone: NO];
    }
  else
    {
      [self _setNeedsDisplay_real: n];
    }
  DESTROY(n);
}


- (void) _setNeedsDisplayInRect_real: (NSValue *)v
{
  NSRect invalidRect = [v rectValue];
  NSView *currentView = _super_view;

  /*
   *	Limit to bounds, combine with old _invalidRect, and then check to see
   *	if the result is the same as the old _invalidRect - if it isn't then
   *	set the new _invalidRect.
   */
  invalidRect = NSIntersectionRect(invalidRect, _bounds);
  invalidRect = NSUnionRect(_invalidRect, invalidRect);
  if (NSEqualRects(invalidRect, _invalidRect) == NO)
    {
      NSView	*firstOpaque = [self opaqueAncestor];

      _rFlags.needs_display = YES;
      _invalidRect = invalidRect;
      if (firstOpaque == self)
	{
	  [_window setViewsNeedDisplay: YES];
	}
      else
	{
	  invalidRect = [firstOpaque convertRect: _invalidRect fromView: self];
	  [firstOpaque setNeedsDisplayInRect: invalidRect];
	}
    }
  /*
   * Must make sure that superviews know that we need display.
   * NB. we may have been marked as needing display and then moved to another
   * parent, so we can't assume that our parent is marked simply because we are.
   */
  while (currentView)
    {
      currentView->_rFlags.needs_display = YES;
      currentView = currentView->_super_view;
    }
}

/**
 * Inform the view system that the specified rectangle is invalid and
 * requires updating.  This automatically informs any superviews of
 * any updating they need to do.
 *
 * As an exception to the general rules for threads and gui, this
 * method is thread-safe and may be called from any thread. Display
 * will always be done in the main thread. (Note that other methods are
 * in general not thread-safe; if you want to access other properties of
 * views from multiple threads, you need to provide the synchronization.)
 */
- (void) setNeedsDisplayInRect: (NSRect)invalidRect
{
  NSValue *v = [[NSValue alloc]
		 initWithBytes: &invalidRect
		 objCType: @encode(NSRect)];
  if (GSCurrentThread() != GSAppKitThread)
    {
      [self performSelectorOnMainThread: @selector(_setNeedsDisplayInRect_real:)
	withObject: v
	waitUntilDone: NO];
    }
  else
    {
      [self _setNeedsDisplayInRect_real: v];
    }
  DESTROY(v);
}

+ (NSFocusRingType) defaultFocusRingType
{
  return NSFocusRingTypeDefault;
}

- (void) setKeyboardFocusRingNeedsDisplayInRect: (NSRect)rect
{
  // FIXME For external type special handling is needed
  [self setNeedsDisplayInRect: rect];
}

- (void) setFocusRingType: (NSFocusRingType)focusRingType
{
  _focusRingType = focusRingType;
}

- (NSFocusRingType) focusRingType
{
  return _focusRingType;
}

/*
 * Hidding Views
 */
- (void) setHidden: (BOOL)flag
{
  _is_hidden = flag;
}

- (BOOL) isHidden
{
  return _is_hidden;
}

- (BOOL) isHiddenOrHasHiddenAncestor
{
  return ([self isHidden] || [_super_view isHiddenOrHasHiddenAncestor]);
}

/*
 * Live resize support
 */
- (BOOL) inLiveResize
{
  return _in_live_resize;
}

- (void) viewWillStartLiveResize
{
  // FIXME
  _in_live_resize = YES; 
}

- (void) viewDidEndLiveResize
{
  // FIXME
  _in_live_resize = NO; 
}

/*
 * Scrolling
 */
- (NSRect) adjustScroll: (NSRect)newVisible
{
  return newVisible;
}

/**
 * Finds the nearest enclosing NSClipView and, if the location of the event
 * is outside it, scrolls the NSClipView in the direction of the event. The
 * amount scrolled is proportional to how far outside the NSClipView the
 * event's location is.
 *
 * This method is suitable for calling periodically from a modal event
 * tracking loop when the mouse is dragged outside the tracking view. The
 * suggested period of the calls is 0.1 seconds.
 */
- (BOOL) autoscroll: (NSEvent*)theEvent
{
  if (_super_view)
    return [_super_view autoscroll: theEvent];

  return NO;
}

- (void) reflectScrolledClipView: (NSClipView*)aClipView
{}

- (void) scrollClipView: (NSClipView*)aClipView toPoint: (NSPoint)aPoint
{}

- (void) scrollPoint: (NSPoint)aPoint
{
  NSClipView	*s = (NSClipView*)_super_view;

  while (s != nil && [s isKindOfClass: [NSClipView class]] == NO)
    {
      s = (NSClipView*)[s superview];
    }

  aPoint = [self convertPoint: aPoint toView: s];
  if (NSEqualPoints(aPoint, [s bounds].origin) == NO)
    {
      [s scrollToPoint: aPoint];
    }
}

- (void) scrollRect: (NSRect)aRect by: (NSSize)delta
{}

/**
Scrolls the nearest enclosing clip view the minimum required distance
necessary to make aRect (or as much of it possible) in the receiver visible.
Returns YES iff any scrolling was done.
*/
- (BOOL) scrollRectToVisible: (NSRect)aRect
{
  NSClipView	*s = (NSClipView*)_super_view;

  while (s != nil && [s isKindOfClass: [NSClipView class]] == NO)
    {
      s = (NSClipView*)[s superview];
    }
  if (s != nil)
    {
      NSRect	vRect = [self visibleRect];
      NSPoint	aPoint = vRect.origin;
      // Ok we assume that the rectangle is origined at the bottom left
      // and goes to the top and right as it grows in size for the naming
      // of these variables
      float ldiff, rdiff, tdiff, bdiff;

      if (vRect.size.width == 0 && vRect.size.height == 0)
	return NO;

      // Find the differences on each side.
      ldiff = NSMinX(vRect) - NSMinX(aRect);
      rdiff = NSMaxX(aRect) - NSMaxX(vRect);
      bdiff = NSMinY(vRect) - NSMinY(aRect);
      tdiff = NSMaxY(aRect) - NSMaxY(vRect);

      // If the diff's have the same sign then nothing needs to be scrolled
      if ((ldiff * rdiff) >= 0.0) ldiff = rdiff = 0.0;
      if ((bdiff * tdiff) >= 0.0) bdiff = tdiff = 0.0;

      // Move the smallest difference
      aPoint.x += (fabs(ldiff) < fabs(rdiff)) ? (-ldiff) : rdiff;
      aPoint.y += (fabs(bdiff) < fabs(tdiff)) ? (-bdiff) : tdiff;

      if (aPoint.x != vRect.origin.x || aPoint.y != vRect.origin.y)
	{
	  aPoint = [self convertPoint: aPoint toView: s];
	  [s scrollToPoint: aPoint];
	  return YES;
	}
    }
  return NO;
}

- (NSScrollView*) enclosingScrollView
{
  id	aView = [self superview];

  while (aView != nil)
    {
      if ([aView isKindOfClass: [NSScrollView class]])
	{
	  break;
	}
      aView = [aView superview];
    }

  return aView;
}

/*
 * Managing the Cursor
 *
 * We use the tracking rectangle class to maintain the cursor rects
 */
- (void) addCursorRect: (NSRect)aRect cursor: (NSCursor*)anObject
{
  if (_window != nil)
    {
      GSTrackingRect	*m;

      aRect = [self convertRect: aRect toView: nil];
      m = [rectClass allocWithZone: NSDefaultMallocZone()];
      m = [m initWithRect: aRect
		      tag: 0
		    owner: anObject
		 userData: NULL
		   inside: YES];
      [_cursor_rects addObject: m];
      RELEASE(m);
      _rFlags.has_currects = 1;
      _rFlags.valid_rects = 1;
    }
}

- (void) discardCursorRects
{
  if (_rFlags.has_currects != 0)
    {
      if (_rFlags.valid_rects != 0)
	{
	  [_cursor_rects makeObjectsPerformSelector: @selector(invalidate)];
	  _rFlags.valid_rects = 0;
	}
      [_cursor_rects removeAllObjects];
      _rFlags.has_currects = 0;
    }
}

- (void) removeCursorRect: (NSRect)aRect cursor: (NSCursor*)anObject
{
  id e = [_cursor_rects objectEnumerator];
  GSTrackingRect	*o;
  NSCursor		*c;

  /* Base remove test upon cursor object */
  o = [e nextObject];
  while (o)
    {
      c = [o owner];
      if (c == anObject)
	{
	  [o invalidate];
	  [_cursor_rects removeObject: o];
	  if ([_cursor_rects count] == 0)
	    {
	      _rFlags.has_currects = 0;
	      _rFlags.valid_rects = 0;
	    }
	  break;
	}
      else
	{
	  o = [e nextObject];
	}
    }
}

- (void) resetCursorRects
{
}

static NSView* findByTag(NSView *view, int aTag, unsigned *level)
{
  unsigned	i, count;
  NSArray	*sub = [view subviews];

  count = [sub count];
  if (count > 0)
    {
      NSView	*array[count];

      [sub getObjects: array];

      for (i = 0; i < count; i++)
	{
	  if ([array[i] tag] == aTag)
	    return array[i];
	}
      *level += 1;
      for (i = 0; i < count; i++)
	{
	  NSView	*v;

	  v = findByTag(array[i], aTag, level);
	  if (v != nil)
	    return v;
	}
      *level -= 1;
    }
  return nil;
}

- (id) viewWithTag: (int)aTag
{
  NSView	*view = nil;

  /*
   * If we have the specified tag - return self.
   */
  if ([self tag] == aTag)
    {
      view = self;
    }
  else if (_rFlags.has_subviews)
    {
      unsigned	count = [_sub_views count];

      if (count > 0)
	{
	  NSView	*array[count];
	  unsigned	i;

	  [_sub_views getObjects: array];

	  /*
	   * Quick check to see if any of our direct descendents has the tag.
	   */
	  for (i = 0; i < count; i++)
	    {
	      NSView *subView = array[i];

	      if ([subView tag] == aTag)
	        {
		  view = subView;
		  break;
		}
	    }

	  if (view == nil)
	    {
	      unsigned	level = 0xffffffff;

	      /*
	       * Ok - do it the long way - search the while tree for each of
	       * our descendents and see which has the closest view matching
	       * the tag.
	       */
	      for (i = 0; i < count; i++)
		{
		  unsigned	l = 0;
		  NSView	*v;

		  v = findByTag(array[i], aTag, &l);

		  if (v != nil && l < level)
		    {
		      view = v;
		      level = l;
		    }
		}
	    }
	}
    }
  return view;
}

/*
 * Aiding Event Handling
 */

/**
 * Returns YES if the view object will accept the first
 * click received when in an inactive window, and NO
 * otherwise.
 */
- (BOOL) acceptsFirstMouse: (NSEvent*)theEvent
{
  return NO;
}

/**
 * Returns the subview, lowest in the receiver's hierarchy, which
 * contains aPoint, or nil if there is no such view.
 */
- (NSView*) hitTest: (NSPoint)aPoint
{
  NSPoint p;
  unsigned count;
  NSView *v = nil, *w;

  /*
  If not within our frame then it can't be a hit.

  As a special case, always assume that it's a hit if our _super_view is nil,
  ie. if we're the top-level view in a window.
  */
  if (_super_view && ![_super_view mouse: aPoint inRect: _frame])
    return nil;

  p = [self convertPoint: aPoint fromView: _super_view];

  if (_rFlags.has_subviews)
    {
      count = [_sub_views count];
      if (count > 0)
	{
	  NSView	*array[count];

	  [_sub_views getObjects: array];

	  while (count > 0)
	    {
	      w = array[--count];
	      v = [w hitTest: p];
	      if (v)
		break;
	    }
	}
    }
  /*
   * mouse is either in the subview or within self
   */
  if (v)
    return v;
  else
    return self;
}

/**
 * Returns whether or not aPoint lies within aRect.
 */
- (BOOL) mouse: (NSPoint)aPoint  inRect: (NSRect)aRect
{
  return NSMouseInRect (aPoint, aRect, _rFlags.flipped_view);
}

- (BOOL) performKeyEquivalent: (NSEvent*)theEvent
{
  unsigned i;

  for (i = 0; i < [_sub_views count]; i++)
    if ([[_sub_views objectAtIndex: i] performKeyEquivalent: theEvent] == YES)
      return YES;
  return NO;
}

- (BOOL) performMnemonic: (NSString *)aString
{
  unsigned i;

  for (i = 0; i < [_sub_views count]; i++)
    if ([[_sub_views objectAtIndex: i] performMnemonic: aString] == YES)
      return YES;
  return NO;
}

- (BOOL) mouseDownCanMoveWindow
{
  // FIXME
  return NO;
}

- (void) removeTrackingRect: (NSTrackingRectTag)tag
{
  unsigned i, j;
  GSTrackingRect	*m;

  j = [_tracking_rects count];
  for (i = 0;i < j; ++i)
    {
      m = (GSTrackingRect*)[_tracking_rects objectAtIndex: i];
      if ([m tag] == tag)
	{
	  [_tracking_rects removeObjectAtIndex: i];
	  if ([_tracking_rects count] == 0)
	    _rFlags.has_trkrects = 0;
	  return;
	}
    }
}

- (BOOL) shouldDelayWindowOrderingForEvent: (NSEvent*)anEvent
{
  return NO;
}

- (NSTrackingRectTag) addTrackingRect: (NSRect)aRect
				owner: (id)anObject
			     userData: (void*)data
			 assumeInside: (BOOL)flag
{
  NSTrackingRectTag	t;
  unsigned		i, j;
  GSTrackingRect	*m;

  t = 0;
  j = [_tracking_rects count];
  for (i = 0; i < j; ++i)
    {
      m = (GSTrackingRect*)[_tracking_rects objectAtIndex: i];
      if ([m tag] > t)
	t = [m tag];
    }
  ++t;

  aRect = [self convertRect: aRect toView: nil];
  m = [[rectClass alloc] initWithRect: aRect
				  tag: t
				owner: anObject
			     userData: data
			       inside: flag];
  [_tracking_rects addObject: m];
  RELEASE(m);
  _rFlags.has_trkrects = 1;
  return t;
}

-(BOOL) needsPanelToBecomeKey
{
  return NO;
}


/**
 * <p>The effect of the -setNextKeyView: method is to set aView to be the
 * value returned by subsequent calls to the receivers -nextKeyView method.
 * This also has the effect of setting the previous key view of aView,
 * so that subsequent calls to its -previousKeyView method will return
 * the receiver.
 * </p>
 * <p>As a special case, if you pass nil as aView then the -previousKeyView
 * of the receivers current -nextKeyView is set to nil as well as the
 * receivers -nextKeyView being set to nil.<br />
 * This behavior provides MacOS-X compatibility.
 * </p>
 * <p>If you pass a non-view object other than nil, an
 * NSInternaInconsistencyException is raised.
 * </p>
 * <p><strong>NB</strong> This method does <em>NOT</em> cause aView to be
 * retained, and if aView is deallocated, the [NSView-dealloc] method will
 * automatically remove it from the key view chain it is in.
 * </p>
 * <p>For keyboard navigation, views are linked together in a chain, so that
 * the current first responder view can be changed by stepping backward
 * and forward in that chain.  This is the method for building and modifying
 * that chain.
 * </p>
 * <p>The MacOS-X documentation refers to this chain as a <em>loop</em>, but
 * the actual implementation is not a loop at all (except as a special case
 * when you make the chain into a loop).  In fact, while each view may have
 * only zero or one <em>next</em> view, and zero or one <em>previous</em>
 * view, several views may have their <em>next</em> view set to a single
 * view and/or their <em>previous</em> views set to a single view.  So the
 * actual setup is a directed graph rather than a loop.
 * </p>
 * <p>While a directed graph is a very powerful and flexible way of managing
 * the way views get keyboard focus in response to  tabs etc, it can be
 * confusing if misused.  It is probably best therefore, to set your views
 * up as a single loop within each window.
 * </p>
 * <example>
 *   [a setNextKeyView: b];
 *   [b setNextKeyView: c];
 *   [c setNextKeyView: d];
 *   [d setNextKeyView: a];
 * </example>
 */
- (void) setNextKeyView: (NSView *)aView
{
  NSView	*tmp;
  unsigned	count;

  if (aView != nil && [aView isKindOfClass: viewClass] == NO)
    {
      [NSException raise: NSInternalInconsistencyException
	format: @"[NSView -setNextKeyView:] passed non-view object %@", aView];
    }

  if (aView == nil)
    {
      if (nKV(self) != 0)
	{
	  tmp = GSIArrayItemAtIndex(nKV(self), 0).obj;
	  if (tmp != nil)
	    {
	      /*
	       * Remove all reference to self from our next key view.
	       */
	      if (pKV(tmp) != 0)
		{
		  count = GSIArrayCount(pKV(tmp));
		  while (count-- > 1)
		    {
		      if (GSIArrayItemAtIndex(pKV(tmp), count).obj == self)
			{
			  GSIArrayRemoveItemAtIndex(pKV(tmp), count);
			}
		    }
		  if (GSIArrayItemAtIndex(pKV(tmp), 0).obj == self)
		    {
		      GSIArraySetItemAtIndex(pKV(tmp), (GSIArrayItem)nil, 0);
		    }
		}
	      /*
	       * Clear link to the next key view.
	       */
	      GSIArraySetItemAtIndex(nKV(self), (GSIArrayItem)nil, 0);
	    }
	}
      return;
    }

  if (nKV(self) == 0)
    {
      /*
       * Create array and ensure that it has a nil item at index 0 ...
       * so we always have room for the pointer to the next view.
       */
      _nextKeyView = NSZoneMalloc(NSDefaultMallocZone(), sizeof(GSIArray_t));
      GSIArrayInitWithZoneAndCapacity(nKV(self), NSDefaultMallocZone(), 1);
      GSIArrayAddItem(nKV(self), (GSIArrayItem)nil);
    }
  else
    {
      /* A safety measure against recursion.  */
      tmp = GSIArrayItemAtIndex(nKV(self), 0).obj;
      if (tmp == aView)
	{
	  return;
	}
    }

  if (pKV(aView) == 0)
    {
      /*
       * Create array and ensure that it has a nil item at index 0 ...
       * so we always have room for the pointer to the previous view.
       */
      aView->_previousKeyView = NSZoneMalloc(NSDefaultMallocZone(), sizeof(GSIArray_t));
      GSIArrayInitWithZoneAndCapacity(pKV(aView), NSDefaultMallocZone(), 1);
      GSIArrayAddItem(pKV(aView), (GSIArrayItem)nil);
    }

  /*
   * Tell the old previous view of aView that aView no longer points to it.
   */
  tmp = GSIArrayItemAtIndex(pKV(aView), 0).obj;
  if (tmp != nil)
    {
      count = GSIArrayCount(nKV(tmp));
      while (count-- > 1)
	{
	  if (GSIArrayItemAtIndex(nKV(tmp), count).obj == aView)
	    {
	      GSIArrayRemoveItemAtIndex(nKV(tmp), count);
	    }
	}
      /*
       * If the view still points to aView, make a note of it in the
       * 'previous' array of aView while making space for the new link.
       */
      if (GSIArrayItemAtIndex(nKV(tmp), 0).obj == aView)
	{
	  GSIArrayInsertItem(pKV(aView), (GSIArrayItem)nil, 0);
	}
    }

  /*
   * Set up 'previous' link in aView to point to us.
   */
  GSIArraySetItemAtIndex(pKV(aView), (GSIArrayItem)((id)self), 0);

  /*
   * Tell our current 'next' view that we are no longer pointing to it.
   */
  tmp = GSIArrayItemAtIndex(nKV(self), 0).obj;
  if (tmp != nil)
    {
      count = GSIArrayCount(pKV(tmp));
      while (count-- > 1)
	{
	  if (GSIArrayItemAtIndex(pKV(tmp), count).obj == self)
	    {
	      GSIArrayRemoveItemAtIndex(pKV(tmp), count);
	    }
	}
      /*
       * If the view still points to us, make a note of it in the
       * 'next' array while making space for the new link to aView.
       */
      if (GSIArrayItemAtIndex(pKV(tmp), 0).obj == self)
	{
	  GSIArrayInsertItem(nKV(self), (GSIArrayItem)nil, 0);
	}
    }

  /*
   * Set up 'next' link to point to aView.
   */
  GSIArraySetItemAtIndex(nKV(self), (GSIArrayItem)((id)aView), 0);
}

/**
 * Returns the next view after the receiver in the key view chain.<br />
 * Returns nil if there is no view after the receiver.<br />
 * The next view is set up using the -setNextKeyView: method.<br />
 * The key view chain is used to determine the order in which views become
 * first responder when using keyboard navigation.
 */
- (NSView *) nextKeyView
{
  if (nKV(self) == 0)
    {
      return nil;
    }
  return GSIArrayItemAtIndex(nKV(self), 0).obj;
}

/**
 * Returns the first available view after the receiver which is
 * actually able to become first responder. See -nextKeyView and
 * [NSResponder-acceptsFirstResponder]
 */
- (NSView *) nextValidKeyView
{
  NSView *theView;

  theView = [self nextKeyView];
  while (1)
    {
      if ((theView == nil) || (theView == self) || 
	  [theView canBecomeKeyView])
	{
	  return theView;
	}
      theView = [theView nextKeyView];
    }
}

/**
 * GNUstep addition ... a conveninece method to insert a view in the
 * key view chain before the receiver, using the -previousKeyView and
 * -setNextKeyView: methods.
 */
- (void) setPreviousKeyView: (NSView *)aView
{
  NSView	*p = [self previousKeyView];

  if (aView == p || aView == self)
    {
      return;
    }
  [p setNextKeyView: aView];
  [aView setNextKeyView: self];
}

/**
 * Returns the view before the receiver in the key view chain.<br />
 * Returns nil if there is no view before the receiver in the chain.<br />
 * The previous view of the receiver was set up by passing it as the
 * argument to a call of -setNextKeyView: on that view.<br />
 * The key view chain is used to determine the order in which views become
 * first responder when using keyboard navigation.
 */
- (NSView *) previousKeyView
{
  if (pKV(self) == 0)
    {
      return nil;
    }
  return GSIArrayItemAtIndex(pKV(self), 0).obj;
}

/**
 * Returns the first available view before the receiver which is
 * actually able to become first responder. See -nextKeyView and
 * [NSResponder-acceptsFirstResponder]
 */
- (NSView *) previousValidKeyView
{
  NSView *theView;

  theView = [self previousKeyView];
  while (1)
    {
      if ((theView == nil) || (theView == self) || 
	  [theView canBecomeKeyView])
	{
	  return theView;
	}
      theView = [theView previousKeyView];
    }
}

- (BOOL) canBecomeKeyView
{
  // FIXME
  return [self acceptsFirstResponder] && ![self isHiddenOrHasHiddenAncestor];
}

/*
 * Dragging
 */
- (BOOL) dragFile: (NSString*)filename
	 fromRect: (NSRect)rect
	slideBack: (BOOL)slideFlag
	    event: (NSEvent*)event
{
  NSImage *anImage = [[NSWorkspace sharedWorkspace] iconForFile: filename];
  NSPasteboard *pboard = [NSPasteboard pasteboardWithName: NSDragPboard];

  if (anImage == nil)
    return NO;

  [pboard declareTypes: [NSArray arrayWithObject: NSFilenamesPboardType] 
	  owner: self];
  if (![pboard setPropertyList: [NSArray arrayWithObject: filename]
	       forType: NSFilenamesPboardType])
    return NO;

  [self dragImage: anImage
	at: rect.origin
	offset: NSMakeSize(0, 0)
	event: event
	pasteboard: pboard
	source: self
	slideBack: slideFlag];
  return YES;
}

- (void) dragImage: (NSImage*)anImage
		at: (NSPoint)viewLocation
	    offset: (NSSize)initialOffset
	     event: (NSEvent*)event
	pasteboard: (NSPasteboard*)pboard
	    source: (id)sourceObject
	 slideBack: (BOOL)slideFlag
{
  [_window dragImage: anImage
	   at: [self convertPoint: viewLocation toView: nil]
	   offset: initialOffset
	   event: event
	   pasteboard: pboard
	   source: sourceObject
	   slideBack: slideFlag];
}

/**
 * Registers the fact that the receiver should accept dragged data
 * of any of the specified types.  You need to do this if you want
 * your view to support drag and drop.
 */
- (void) registerForDraggedTypes: (NSArray*)newTypes
{
  NSArray	*o;
  NSArray	*t;

  if (newTypes == nil || [newTypes count] == 0)
    [NSException raise: NSInvalidArgumentException
		format: @"Types information missing"];

  /*
   * Get the old drag types for this view if we need to tell the context
   * to change the registered types for the window.
   */
  if (_rFlags.has_draginfo == 1 && _window != nil)
    {
      o = GSGetDragTypes(self);
      TEST_RETAIN(o);
    }
  else
    {
      o = nil;
    }

  t = GSSetDragTypes(self, newTypes);
  _rFlags.has_draginfo = 1;
  if (_window != nil)
    {

      [GSDisplayServer addDragTypes: t toWindow: _window];
      if (o != nil)
	{
	  [GSDisplayServer removeDragTypes: o fromWindow: _window];
	}
    }
  TEST_RELEASE(o);
}

- (void) unregisterDraggedTypes
{
  if (_rFlags.has_draginfo)
    {
      if (_window != nil)
	{
	  NSArray		*t = GSGetDragTypes(self);

	  [GSDisplayServer removeDragTypes: t fromWindow: _window];
	}
      GSRemoveDragTypes(self);
      _rFlags.has_draginfo = 0;
    }
}

- (BOOL) dragPromisedFilesOfTypes: (NSArray *)typeArray
                         fromRect: (NSRect)aRect
                           source: (id)sourceObject 
                        slideBack: (BOOL)slideBack
                            event: (NSEvent *)theEvent
{
  // FIXME
  return NO;
}

/*
 * Printing
 */
- (void) fax: (id)sender
{
  NSPrintInfo *aPrintInfo = [NSPrintInfo sharedPrintInfo];

  [aPrintInfo setJobDisposition: NSPrintFaxJob];
  [[NSPrintOperation printOperationWithView: self
		     printInfo: aPrintInfo] runOperation];
}

- (void) print: (id)sender
{
  [[NSPrintOperation printOperationWithView: self] runOperation];
}

- (NSData*) dataWithEPSInsideRect: (NSRect)aRect
{
  NSMutableData *data = [NSMutableData data];

  [[NSPrintOperation EPSOperationWithView: self
		     insideRect: aRect
		     toData: data] runOperation];

  return data;
}

- (void) writeEPSInsideRect: (NSRect)rect
	       toPasteboard: (NSPasteboard*)pasteboard
{
  NSData *data = [self dataWithEPSInsideRect: rect];

  if (data != nil)
    [pasteboard setData: data
		forType: NSPostScriptPboardType];
}

- (NSData *)dataWithPDFInsideRect:(NSRect)aRect
{
  NSMutableData *data = [NSMutableData data];
  
  [[NSPrintOperation PDFOperationWithView: self
		     insideRect: aRect
		     toData: data] runOperation];
  return data;
}

- (void)writePDFInsideRect:(NSRect)aRect 
	      toPasteboard:(NSPasteboard *)pboard
{
  NSData *data = [self dataWithPDFInsideRect: aRect];

  if (data != nil)
    [pboard setData: data
	    forType: NSPDFPboardType];
}

- (NSString *)printJobTitle
{
  id doc;
  NSString *title;
  doc = [[NSDocumentController sharedDocumentController] documentForWindow:
							   [self window]];
  if (doc)
    title = [doc displayName];
  else
    title = [[self window] title];
  return title;
}

/*
 * Pagination
 */
- (void) adjustPageHeightNew: (float*)newBottom
			 top: (float)oldTop
		      bottom: (float)oldBottom
		       limit: (float)bottomLimit
{
  float bottom = oldBottom;

  if (_rFlags.has_subviews)
    {
      id e, o;

      e = [_sub_views objectEnumerator];
      while ((o = [e nextObject]) != nil)
	{
          // FIXME: We have to convert this values for the subclass

	  float oTop, oBottom, oLimit;
	  /* Don't ask me why, but gcc-2.91.66 crashes if we use
	     NSMakePoint in the following expressions.  We avoid this
	     compiler internal bug by using an auxiliary aPoint
	     variable, and setting it manually to the NSPoints we
	     need.  */
	  {
	    NSPoint aPoint = {0, oldTop};
	    oTop = ([self convertPoint: aPoint  toView: o]).y;
	  }
	  
	  {
	    NSPoint aPoint = {0, bottom};
	    oBottom = ([self convertPoint: aPoint  toView: o]).y;
	  }

	  {
	    NSPoint aPoint = {0, bottomLimit};
	    oLimit = ([self convertPoint: aPoint  toView: o]).y;
	  }

	  [o adjustPageHeightNew: &oBottom
	     top: oTop
	     bottom: oBottom
	     limit: oLimit];

	  {
	    NSPoint aPoint = {0, oBottom};
	    bottom = ([self convertPoint: aPoint  fromView: o]).y; 
	  }	    
	}
    }

  *newBottom = bottom;
}

- (void) adjustPageWidthNew: (float*)newRight
		       left: (float)oldLeft
		      right: (float)oldRight
		      limit: (float)rightLimit
{
  float right = oldRight;

  if (_rFlags.has_subviews)
    {
      id e, o;

      e = [_sub_views objectEnumerator];
      while ((o = [e nextObject]) != nil)
	{
          // FIXME: We have to convert this values for the subclass

	  /* See comments in adjustPageHeightNew:top:bottom:limit:
	     about why code is structured in this funny way.  */
	  float oLeft, oRight, oLimit;
	  /* Don't ask me why, but gcc-2.91.66 crashes if we use
	     NSMakePoint in the following expressions.  We avoid this
	     compiler internal bug by using an auxiliary aPoint
	     variable, and setting it manually to the NSPoints we
	     need.  */
	  {
	    NSPoint aPoint = {oldLeft, 0};
	    oLeft = ([self convertPoint: aPoint  toView: o]).x;
	  }
	  
	  {
	    NSPoint aPoint = {right, 0};
	    oRight = ([self convertPoint: aPoint  toView: o]).x;
	  }

	  {
	    NSPoint aPoint = {rightLimit, 0};
	    oLimit = ([self convertPoint: aPoint  toView: o]).x;
	  }

	  [o adjustPageHeightNew: &oRight
	     top: oLeft
	     bottom: oRight
	     limit: oLimit];

	  {
	    NSPoint aPoint = {oRight, 0};
	    right = ([self convertPoint: aPoint  fromView: o]).x; 
	  }	    
	}
    }

  *newRight = right;
}

- (float) heightAdjustLimit
{
  return 0;
}

- (BOOL) knowsPagesFirst: (int*)firstPageNum last: (int*)lastPageNum
{
  return NO;
}

- (BOOL) knowsPageRange: (NSRange*)range
{
  return NO;
}

- (NSPoint) locationOfPrintRect: (NSRect)aRect
{
  int pages;
  NSPoint location;
  NSRect bounds;
  NSMutableDictionary *dict;
  NSPrintOperation *printOp = [NSPrintOperation currentOperation];
  NSPrintInfo *printInfo = [printOp printInfo];
  dict = [printInfo dictionary];

  pages = [[dict objectForKey: @"NSPrintTotalPages"] intValue];
  if ([dict objectForKey: @"NSPrintPaperBounds"])
    bounds = [[dict objectForKey: @"NSPrintPaperBounds"] rectValue];
  else
    bounds = aRect;
  location = NSMakePoint(0, NSHeight(bounds)-NSHeight(aRect));
  /* FIXME:  I can't figure out how the location for a multi-page document
     is computed. Just ignore centering? */
  if (pages == 1)
    {
      if ([printInfo isHorizontallyCentered])
	location.x = (NSWidth(bounds) - NSWidth(aRect))/2;
      if ([printInfo isVerticallyCentered])
	location.y = (NSHeight(bounds) - NSHeight(aRect))/2;
    }

  return location;
}

- (NSRect) rectForPage: (int)page
{
  return NSZeroRect;
}

- (float) widthAdjustLimit
{
  return 0;
}

/*
 * Writing Conforming PostScript
 */
- (void) beginPage: (int)ordinalNum
	     label: (NSString*)aString
	      bBox: (NSRect)pageRect
	     fonts: (NSString*)fontNames
{
  NSGraphicsContext *ctxt = GSCurrentContext();

  if (aString == nil)
    aString = [[NSNumber numberWithInt: ordinalNum] description];
  DPSPrintf(ctxt, "%%%%Page: %s %d\n", [aString lossyCString], ordinalNum);
  if (NSIsEmptyRect(pageRect) == NO)
    DPSPrintf(ctxt, "%%%%PageBoundingBox: %d %d %d %d\n",
	      (int)NSMinX(pageRect), (int)NSMinY(pageRect), 
	      (int)NSMaxX(pageRect), (int)NSMaxY(pageRect));
  if (fontNames)
    DPSPrintf(ctxt, "%%%%PageFonts: %s\n", [fontNames lossyCString]);
  DPSPrintf(ctxt, "%%%%BeginPageSetup\n");
}

- (void) beginPageSetupRect: (NSRect)aRect placement: (NSPoint)location
{
  [self beginPageInRect: aRect atPlacement: location];
}

- (void) beginPrologueBBox: (NSRect)boundingBox
	      creationDate: (NSString*)dateCreated
		 createdBy: (NSString*)anApplication
		     fonts: (NSString*)fontNames
		   forWhom: (NSString*)user
		     pages: (int)numPages
		     title: (NSString*)aTitle
{
  NSGraphicsContext *ctxt = GSCurrentContext();
  NSPrintOperation *printOp = [NSPrintOperation currentOperation];
  NSPrintingOrientation orient;
  BOOL epsOp;

  epsOp = [printOp isEPSOperation];
  orient = [[printOp printInfo] orientation];

  if (epsOp)
    DPSPrintf(ctxt, "%%!PS-Adobe-3.0 EPSF-3.0\n");
  else
    DPSPrintf(ctxt, "%%!PS-Adobe-3.0\n");
  DPSPrintf(ctxt, "%%%%Title: %s\n", [aTitle lossyCString]);
  DPSPrintf(ctxt, "%%%%Creator: %s\n", [anApplication lossyCString]);
  DPSPrintf(ctxt, "%%%%CreationDate: %s\n", 
	    [[dateCreated description] lossyCString]);
  DPSPrintf(ctxt, "%%%%For: %s\n", [user lossyCString]);
  if (fontNames)
    DPSPrintf(ctxt, "%%%%DocumentFonts: %s\n", [fontNames lossyCString]);
  else
    DPSPrintf(ctxt, "%%%%DocumentFonts: (atend)\n");

  if (NSIsEmptyRect(boundingBox) == NO)
    DPSPrintf(ctxt, "%%%%BoundingBox: %d %d %d %d\n", 
    	      (int)NSMinX(boundingBox), (int)NSMinY(boundingBox), 
	      (int)NSMaxX(boundingBox), (int)NSMaxY(boundingBox));
  else
    DPSPrintf(ctxt, "%%%%BoundingBox: (atend)\n");

  if (epsOp == NO)
    {
      if (numPages)
	DPSPrintf(ctxt, "%%%%Pages: %d\n", numPages);
      else
	DPSPrintf(ctxt, "%%%%Pages: (atend)\n");
      if ([printOp pageOrder] == NSDescendingPageOrder)
	DPSPrintf(ctxt, "%%%%PageOrder: Descend\n");
      else if ([printOp pageOrder] == NSAscendingPageOrder)
	DPSPrintf(ctxt, "%%%%PageOrder: Ascend\n");
      else if ([printOp pageOrder] == NSSpecialPageOrder)
	DPSPrintf(ctxt, "%%%%PageOrder: Special\n");

      if (orient == NSPortraitOrientation)
	DPSPrintf(ctxt, "%%%%Orientation: Portrait\n");
      else
	DPSPrintf(ctxt, "%%%%Orientation: Landscape\n");
    }

  DPSPrintf(ctxt, "%%%%GNUstepVersion: %d.%d.%d\n", 
	    GNUSTEP_GUI_MAJOR_VERSION, GNUSTEP_GUI_MINOR_VERSION,
	    GNUSTEP_GUI_SUBMINOR_VERSION);
}

- (void) addToPageSetup
{
}

- (void) beginSetup
{
  NSGraphicsContext *ctxt = GSCurrentContext();
  DPSPrintf(ctxt, "%%%%BeginSetup\n");
}

- (void) beginTrailer
{
  NSGraphicsContext *ctxt = GSCurrentContext();
  DPSPrintf(ctxt, "%%%%Trailer\n");
}

- (void) drawPageBorderWithSize: (NSSize)borderSize
{
}

- (void) drawSheetBorderWithSize: (NSSize)borderSize
{
}

- (void) endHeaderComments
{
  NSGraphicsContext *ctxt = GSCurrentContext();
  DPSPrintf(ctxt, "%%%%EndComments\n\n");
}

- (void) endPrologue
{
  NSGraphicsContext *ctxt = GSCurrentContext();
  DPSPrintf(ctxt, "%%%%EndProlog\n\n");
}

- (void) endSetup
{
  NSGraphicsContext *ctxt = GSCurrentContext();
  DPSPrintf(ctxt, "%%%%EndSetup\n\n");
}

- (void) endPageSetup
{
  NSGraphicsContext *ctxt = GSCurrentContext();
  DPSPrintf(ctxt, "%%%%EndPageSetup\n");
}

- (void) endPage
{
  int nup;
  NSGraphicsContext *ctxt = GSCurrentContext();
  NSPrintOperation *printOp = [NSPrintOperation currentOperation];
  NSDictionary *dict = [[printOp printInfo] dictionary];

  nup = [[dict objectForKey: NSPrintPagesPerSheet] intValue];
  if (nup > 1)
    {
      DPSPrintf(ctxt, "__GSpagesaveobject restore\n\n");
    }
}

- (void) endTrailer
{
  NSGraphicsContext *ctxt = GSCurrentContext();
  DPSPrintf(ctxt, "%%%%EOF\n");
}

- (void) _loadPrinterProlog: (NSGraphicsContext *)ctxt
{
  NSString *prolog;
  prolog = [NSBundle pathForLibraryResource: @"GSProlog"
				   ofType: @"ps"
			      inDirectory: @"PostScript"];
  if (prolog == nil)
    {
      NSLog(@"Cannot find printer prolog file");
      return;
    }
  prolog = [NSString stringWithContentsOfFile: prolog];
  DPSPrintf(ctxt, [prolog cString]);
}


/** 
    Writes header and job information for the PostScript document. This
    includes at a minimum, PostScript header information. It may also 
    include job setup information if the output is intended for a printer
    (i.e. not an EPS file). Most of the information for writing the
    header comes from the NSPrintOperation and NSPrintInfo objects 
    associated with the current print operation.

    There isn't normally anything that the program needs to override
    at the beginning of a document, although if there is additional
    setup that needs to be done, you can override the NSView's methods
    endHeaderComments, endPrologue, beginSetup, and/or endSetup.

    This method calls the above methods in the listed order before
    or after writing the required information. For an EPS operation, the
    beginSetup and endSetup methods aren't used.  */
- (void)beginDocument
{
  int first, last, pages, nup;
  NSRect bbox;
  NSDictionary *dict;
  NSGraphicsContext *ctxt = GSCurrentContext();
  NSPrintOperation *printOp = [NSPrintOperation currentOperation];
  dict = [[printOp printInfo] dictionary];
  if (printOp == nil)
    {
      [NSException raise: NSInternalInconsistencyException
		  format: @"beginDocument called without a current print op"];
    }
  /* Inform ourselves and subviews that we're printing so we adjust
     the PostScript accordingly. Perhaps this could be in the thread
     dictionary, but that's probably overkill and slow */
  viewIsPrinting = self;

  /* Get pagination information */
  nup = [[dict objectForKey: NSPrintPagesPerSheet] intValue];
  bbox = NSZeroRect;
  if ([dict objectForKey: @"NSPrintSheetBounds"])
    bbox = [[dict objectForKey: @"NSPrintSheetBounds"] rectValue];
  first = [[dict objectForKey: NSPrintFirstPage] intValue];
  last  = [[dict objectForKey: NSPrintLastPage] intValue];
  pages = last - first + 1;
  if (nup > 1)
    pages = ceil((float)pages / nup);

  /* Begin document structure */
  [self beginPrologueBBox: bbox
	     creationDate: [[NSCalendarDate calendarDate] description]
	        createdBy: [[NSProcessInfo processInfo] processName]
		    fonts: nil
	          forWhom: NSUserName()
		    pages: pages
	            title: [self printJobTitle]];
  [self endHeaderComments];

  DPSPrintf(ctxt, "%%%%BeginProlog\n");
  [self _loadPrinterProlog: ctxt];
  [self endPrologue];
  if ([printOp isEPSOperation] == NO)
    {
      [self beginSetup];
      // Setup goes here !
      [self endSetup];
    }

  [ctxt resetUsedFonts];
  /* Make sure we set the visible rect so everything is printed. */
  [self _rebuildCoordinates];
  _visibleRect = _bounds;
}

- (void)beginPageInRect:(NSRect)aRect 
	    atPlacement:(NSPoint)location
{
  int nup;
  float scale;
  NSRect bounds;
  NSGraphicsContext *ctxt = GSCurrentContext();
  NSPrintOperation *printOp = [NSPrintOperation currentOperation];
  NSDictionary *dict = [[printOp printInfo] dictionary];

  if ([dict objectForKey: @"NSPrintPaperBounds"])
    bounds = [[dict objectForKey: @"NSPrintPaperBounds"] rectValue];
  else
    bounds = aRect;
      
  nup = [[dict objectForKey: NSPrintPagesPerSheet] intValue];
  if (nup > 1)
    {
      int page;
      float xoff, yoff;
      DPSPrintf(ctxt, "/__GSpagesaveobject save def\n");
      page = [printOp currentPage] 
	- [[dict objectForKey: NSPrintFirstPage] intValue];
      page = page % nup;
      scale = [[dict objectForKey: @"NSNupScale"] floatValue];
      if (nup == 2)
	xoff = page;
      else
	xoff = (page % (nup/2));
      xoff *= NSWidth(bounds) * scale;
      if (nup == 2)
	yoff = 0;
      else
	yoff = (int)((nup-page-1) / (nup/2));
      yoff *= NSHeight(bounds) * scale;
      DPStranslate(ctxt, xoff, yoff);
      DPSgsave(ctxt);
      DPSscale(ctxt, scale, scale);
    }
  else
    DPSgsave(ctxt);

  /* Translate to placement */
  if (location.x != 0 || location.y != 0)
    DPStranslate(ctxt, location.x, location.y);
}

- (void)endDocument
{
  int first, last, current, pages;
  NSSet *fontNames;
  NSGraphicsContext *ctxt = GSCurrentContext();
  NSPrintOperation *printOp = [NSPrintOperation currentOperation];
  NSDictionary *dict = [[printOp printInfo] dictionary];

  first = [[dict objectForKey: NSPrintFirstPage] intValue];
  last  = [[dict objectForKey: NSPrintLastPage] intValue];
  pages = last - first + 1;
  [self beginTrailer];

  if (pages == 0)
    {
      int nup = [[dict objectForKey: NSPrintPagesPerSheet] intValue];
      current = [printOp currentPage];
      pages = current - first; // Current is 1 more than the last page
      if (nup > 1)
	pages = ceil((float)pages / nup);
      DPSPrintf(ctxt, "%%%%Pages: %d\n", pages);
    }
  fontNames = [ctxt usedFonts];
  if (fontNames && [fontNames count])
    {
      NSString *name;
      NSEnumerator *e = [fontNames objectEnumerator];
      DPSPrintf(ctxt, "%%%%DocumentFonts: %@\n", [e nextObject]);
      while ((name = [e nextObject]))
	{
	  DPSPrintf(ctxt, "%%%%+ %@\n", name);
	}
    }

  [self endTrailer];
  [self _invalidateCoordinates];
  viewIsPrinting = nil;
}

/* An exception occured while printing. Clean up */
- (void) _cleanupPrinting
{
  [self _invalidateCoordinates];
  viewIsPrinting = nil;
}  

/*
 * NSCoding protocol
 */
- (void) encodeWithCoder: (NSCoder*)aCoder
{
  if ([aCoder allowsKeyedCoding])
    {
      int vFlags = 0;

      // encoding
      [aCoder encodeConditionalObject: [self nextKeyView] 
	      forKey: @"NSNextKeyView"];
      [aCoder encodeConditionalObject: [self previousKeyView] 
	      forKey: @"NSPreviousKeyView"];
      [aCoder encodeObject: _sub_views 
	      forKey: @"NSSubviews"];
      [aCoder encodeRect: _frame 
	      forKey: @"NSFrame"];

      // autosizing masks.
      vFlags = _autoresizingMask;

      // add the autoresize flag.
      if (_autoresizes_subviews)
	{
	  vFlags |= 0x100;
	}

      // add the hidden flag
      if (_is_hidden)
	{
	  vFlags |= 0x80000000;
	}
      
      [aCoder encodeInt: vFlags 
	      forKey: @"NSvFlags"];
    }
  else
    {
      NSDebugLLog(@"NSView", @"NSView: start encoding\n");
      [super encodeWithCoder: aCoder];

      [aCoder encodeRect: _frame];
      [aCoder encodeRect: _bounds];
      [aCoder encodeValueOfObjCType: @encode(BOOL) at: &_is_rotated_from_base];
      [aCoder encodeValueOfObjCType: @encode(BOOL)
	      at: &_is_rotated_or_scaled_from_base];
      [aCoder encodeValueOfObjCType: @encode(BOOL) at: &_post_frame_changes];
      [aCoder encodeValueOfObjCType: @encode(BOOL) at: &_autoresizes_subviews];
      [aCoder encodeValueOfObjCType: @encode(unsigned int) at: &_autoresizingMask];
      [aCoder encodeConditionalObject: [self nextKeyView]];
      [aCoder encodeConditionalObject: [self previousKeyView]];
      [aCoder encodeObject: _sub_views];
      NSDebugLLog(@"NSView", @"NSView: finish encoding\n");
    }
}

- (id) initWithCoder: (NSCoder*)aDecoder
{
  // decode the superclass...
  [super initWithCoder: aDecoder];

  // initialize these here, since they're needed in either case.
  _frameMatrix = [NSAffineTransform new];     // Map fromsuperview to frame
  _boundsMatrix = [NSAffineTransform new];    // Map fromsuperview to bounds
  _matrixToWindow = [NSAffineTransform new];  // Map to window coordinates
  _matrixFromWindow = [NSAffineTransform new];// Map from window coordinates
 
  if ([aDecoder allowsKeyedCoding])
    {
      NSView *prevKeyView = [aDecoder decodeObjectForKey: @"NSPreviousKeyView"];
      NSView *nextKeyView = [aDecoder decodeObjectForKey: @"NSNextKeyView"];
      NSArray *subViews = [aDecoder decodeObjectForKey: @"NSSubviews"];
      
      if ([aDecoder containsValueForKey: @"NSFrame"])
	{
	  _frame = [aDecoder decodeRectForKey: @"NSFrame"];
	  [_frameMatrix setFrameOrigin: _frame.origin];
	}
      self = [self initWithFrame: _frame];
      
      if (subViews != nil)
	{
	  NSEnumerator *enumerator = [subViews objectEnumerator];
	  NSView *sub;
	  
	  while ((sub = [enumerator nextObject]) != nil)
	    {
	      [self addSubview: sub];
	    }
	}
      if (nextKeyView != nil)
	{
	  [self setNextKeyView: nextKeyView];
	}
      if (prevKeyView != nil)
	{
	  [self setPreviousKeyView: prevKeyView];
	}
      if ([aDecoder containsValueForKey: @"NSvFlags"])
	{
	  int vFlags = [aDecoder decodeIntForKey: @"NSvFlags"];
	  
	  // We are lucky here, Apple use the same constants
	  // in the lower bits of the flags
	  [self setAutoresizingMask: vFlags & 0x3F];
	  [self setAutoresizesSubviews: ((vFlags & 0x100) == 0x100)];
	  [self setHidden: ((vFlags & 0x80000000) == 0x80000000)];
	}
    }
  else
    {
      NSRect	rect;
      NSEnumerator *e;
      NSView	*sub;
      NSArray	*subs;
      
      NSDebugLLog(@"NSView", @"NSView: start decoding\n");

      _frame = [aDecoder decodeRect];
      
      _bounds.origin = NSZeroPoint;
      _bounds.size = _frame.size;
      [_frameMatrix setFrameOrigin: _frame.origin];
      
      rect = [aDecoder decodeRect];
      [self setBounds: rect];
      
      _sub_views = [NSMutableArray new];
      _tracking_rects = [NSMutableArray new];
      _cursor_rects = [NSMutableArray new];
      
      _super_view = nil;
      _window = nil;
      _rFlags.needs_display = YES;
      _coordinates_valid = NO;
      
      _rFlags.flipped_view = [self isFlipped];
      
      [aDecoder decodeValueOfObjCType: @encode(BOOL) at: &_is_rotated_from_base];
      [aDecoder decodeValueOfObjCType: @encode(BOOL)
		at: &_is_rotated_or_scaled_from_base];
      [aDecoder decodeValueOfObjCType: @encode(BOOL) at: &_post_frame_changes];
      [aDecoder decodeValueOfObjCType: @encode(BOOL) at: &_autoresizes_subviews];
      [aDecoder decodeValueOfObjCType: @encode(unsigned int)
		at: &_autoresizingMask];
      [self setNextKeyView: [aDecoder decodeObject]];
      [[aDecoder decodeObject] setNextKeyView: self];
      
      [aDecoder decodeValueOfObjCType: @encode(id) at: &subs];
      e = [subs objectEnumerator];
      while ((sub = [e nextObject]) != nil)
	{
	  NSAssert(sub->_window == nil, NSInternalInconsistencyException);
	  NSAssert(sub->_super_view == nil, NSInternalInconsistencyException);
	  [sub viewWillMoveToWindow: _window];
	  [sub viewWillMoveToSuperview: self];
	  [sub setNextResponder: self];
	  [_sub_views addObject: sub];
	  _rFlags.has_subviews = 1;
	  [sub resetCursorRects];
	  [sub setNeedsDisplay: YES];
	  [sub _viewDidMoveToWindow];
	  [sub viewDidMoveToSuperview];
	  [self didAddSubview: sub];
	}
      RELEASE(subs);
      NSDebugLLog(@"NSView", @"NSView: finish decoding\n");
    }
        
  return self;
}

/*
 * Accessor methods
 */
- (void) setAutoresizesSubviews: (BOOL)flag
{
  _autoresizes_subviews = flag;
}

- (void) setAutoresizingMask: (unsigned int)mask
{
  _autoresizingMask = mask;
}

/** Returns the window in which the receiver resides. */
- (NSWindow*) window
{
  return _window;
}

- (BOOL) autoresizesSubviews
{
  return _autoresizes_subviews;
}

- (unsigned int) autoresizingMask
{
  return _autoresizingMask;
}

- (NSArray*) subviews
{
  /*
   * Return a mutable copy 'cos we know that a mutable copy of an array or
   * a mutable array does a shallow copy - which is what we want to give
   * away - we don't want people to mess with our actual subviews array.
   */
  return AUTORELEASE([_sub_views mutableCopyWithZone: NSDefaultMallocZone()]);
}

- (NSView*) superview
{
  return _super_view;
}

- (BOOL) shouldDrawColor
{
  return YES;
}

- (BOOL) isOpaque
{
  return NO;
}

- (BOOL) needsDisplay
{
  return _rFlags.needs_display;
}

- (int) tag
{
  return -1;
}

- (BOOL) isFlipped
{
  return NO;
}

- (NSRect) bounds
{
  return _bounds;
}

- (NSRect) frame
{
  return _frame;
}

- (float) boundsRotation
{
  return [_boundsMatrix rotationAngle];
}

- (float) frameRotation
{
  return [_frameMatrix rotationAngle];
}

- (BOOL) postsFrameChangedNotifications
{
  return _post_frame_changes;
}

- (BOOL) postsBoundsChangedNotifications
{
  return _post_bounds_changes;
}


/**
 * <p>Returns the default menu to be used for instances of the 
 *    current class; if no menu has been set through setMenu:
 *    this default menu will be used.
 * </p>
 * <p>NSView's implementation returns nil. You should override
 *    this method if you want all instances of your custom view
 *    to use the same menu.
 * </p>
 */
+ (NSMenu *)defaultMenu
{
  return nil;
}

/**
 * <p>NSResponder's method, overriden by NSView.</p>
 * <p>If no menu has been set through the use of setMenu:, or 
 *    if a nil value has been set through setMenu:, then the 
 *    value returned by defaultMenu is used. Otherwise this
 *    method returns the menu set through NSResponder.
 * <p>
 * <p> see [NSResponder -menu], [NSResponder -setMenu:],
 *     [NSView +defaultMenu] and [NSView -menuForEvent:].
 * </p>
 */
- (NSMenu *)menu
{
  NSMenu *m = [super menu];
  if (m)
    {
      return m;
    }
  else
    {
      return [[self class] defaultMenu];
    }
}

/**
 * <p>Returns the menu that it appropriates for the given 
 *    event. NSView's implementation returns the default menu of
 *    the view.</p>
 * <p>This methods is intended to be overriden so that it can
 *    return a context-sensitive for appropriate mouse's events. (
 *    (although it seems it can be used for any kind of event)</p>
 * <p>This method is used by NSView's rightMouseDown: method, 
 *    and the returned NSMenu is displayed as a context menu</p> 
 * <p>Use of this method is discouraged in GNUstep as it breaks many
 *    user interface guidelines. At the very least, menu items that appear
 *    in a context sensitive menu should also always appear in a normal
 *    menu. Otherwise, users are faced with an inconsistant interface where
 *    the menu items they want are only available in certain (possibly
 *    unknown) cases, making it difficult for the user to understand how
 *    the application operates</p>
 * <p> see [NSResponder -menu], [NSResponder -setMenu:],
 *     [NSView +defaultMenu] and [NSView -menu].
 * </p>
 */
- (NSMenu *)menuForEvent:(NSEvent *)theEvent
{
  return [self menu];
}

/*
 * Tool Tips
 */

- (NSToolTipTag) addToolTipRect: (NSRect)aRect 
			  owner: (id)anObject 
		       userData: (void *)data
{
  return 0;
}

- (void) removeAllToolTips
{
}

- (void) removeToolTip: (NSToolTipTag)tag
{
}

- (void) setToolTip: (NSString *)string
{
}

- (NSString *) toolTip
{
  return nil;
}

- (void) rightMouseDown: (NSEvent *) theEvent
{
  NSMenu *m;
  m = [self menuForEvent: theEvent];
  if (m)
    {
      [NSMenu popUpContextMenu: m
	      withEvent: theEvent
	      forView: self];
    }
  else
    {
      [super rightMouseDown: theEvent];
    }
}

- (BOOL) shouldBeTreatedAsInkEvent: (NSEvent *)theEvent
{
  return YES;
}

@end

