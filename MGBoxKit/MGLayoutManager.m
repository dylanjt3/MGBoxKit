//
//  Created by matt on 14/06/12.
//

#import "MGLayoutManager.h"
#import "MGScrollView.h"
#import "MGBoxProvider.h"
#import <tgmath.h>

CGFloat roundToPixel(CGFloat value) {
  return UIScreen.mainScreen.scale == 1 ? round(value) : round(value * 2.0) / 2.0;
}

@implementation MGLayoutManager

+ (void)layoutBoxesIn:(UIView <MGLayoutBox> *)container {

  // layout locked?
  if (container.layingOut) {
    return;
  }
  container.layingOut = YES;

    // box provider style layout
    if (container.boxProvider) {
        [self positionBoxesIn:container];
        [container.boxProvider updateDataKeys];
        [container.boxProvider updateVisibleIndexes];
        [container.boxProvider updateVisibleBoxes];
        [self layoutVisibleBoxesIn:container duration:0 completion:nil];
        container.layingOut = NO;
        return;
    }

  // goners
  NSArray *gone = [MGLayoutManager findBoxesInView:container
      notInSet:container.boxes];
  [gone makeObjectsPerformSelector:@selector(removeFromSuperview)];

  // everyone in now please
  for (UIView <MGLayoutBox> *box in container.boxes) {
    NSAssert([box conformsToProtocol:@protocol(MGLayoutBox)], @"Items in the boxes set must conform to MGLayoutBox");
    [container addSubview:box];
    box.parentBox = container;
  }

  // children layout first
  if (!container.dontLayoutChildren) {
    for (id <MGLayoutBox> box in container.boxes) {
      [box layout];
    }
  }

  // positioning time
  [MGLayoutManager positionBoxesIn:container];

  // release the lock
  container.layingOut = NO;
}

+ (void)layoutVisibleBoxesIn:(UIView <MGLayoutBox> *)container
      duration:(NSTimeInterval)duration completion:(Block)completion {
    MGBoxProvider *provider = container.boxProvider;

    NSMutableOrderedSet *toAdd = NSMutableOrderedSet.orderedSet;
    NSMutableOrderedSet *toMove = NSMutableOrderedSet.orderedSet;
    NSArray *toRemove = [MGLayoutManager findBoxesInView:container
          notInSet:provider.visibleBoxes.allValues];

    // find existing boxes and add new boxes
    for (UIView <MGLayoutBox> *box in provider.visibleBoxes.allValues) {
        if (box.superview == container) {
            [toMove addObject:box];
        } else {
            box.frame = [provider frameForBox:box];
            box.parentBox = container;
            [container addSubview:box];
            [toAdd addObject:box];
        }
    };

    // do changes / animations
    if (duration) {
        for (UIView <MGLayoutBox> *box in toRemove) {
            NSUInteger index = [provider oldIndexOfBox:box];
            if (index == NSNotFound || [provider dataAtIndexIsOld:index]) {
                [provider doDisappearAnimationFor:box atIndex:index duration:duration];
            }
        }
        for (UIView <MGLayoutBox> *box in toAdd) {
            NSUInteger index = [provider indexOfBox:box];
            if ([provider dataAtIndexIsNew:index]) {
                [provider doAppearAnimationFor:box atIndex:index duration:duration];
            }
        }
    }
    for (UIView <MGLayoutBox> *box in toMove) {
        CGRect toFrame = [provider frameForBox:box];
        if (!CGRectEqualToRect(toFrame, box.frame)) {
            if (duration) {
                NSUInteger index = [provider indexOfBox:box];
                [provider doMoveAnimationFor:box atIndex:index duration:duration
                      fromFrame:box.frame toFrame:toFrame];
            } else {
                box.frame = toFrame;
            }
        }
    }
    [self updateContentSizeFor:container];

    for (UIView <MGLayoutBox> *box in toRemove) {
        if ([box respondsToSelector:@selector(disappeared)]) {
            [box disappeared];
        }
    }
    for (UIView <MGLayoutBox> *box in toAdd) {
        if ([box respondsToSelector:@selector(appeared)]) {
            [box appeared];
        }
    }

    Block fini = ^{
        for (UIView <MGLayoutBox> *box in toRemove) {
            [box removeFromSuperview];
        }
        completion();
    };

    if (completion) {
        if (duration) {
            dispatch_time_t delay = dispatch_time(0, (int64_t)duration * NSEC_PER_SEC);
            dispatch_after(delay, dispatch_get_main_queue(), ^{
                fini();
            });
        } else {
            fini();
        }
    }
}

+ (void)positionBoxesIn:(UIView <MGLayoutBox> *)container {
    if (container.boxProvider) {
        switch (container.contentLayoutMode) {
            case MGLayoutTableStyle:
                [self stackTableStyle:container];
                break;
            case MGLayoutGridStyle:
                [self stackGridStyle:container];
                break;
        }
    } else {
        switch (container.contentLayoutMode) {
            case MGLayoutTableStyle:
                [self stackTableStyle:container onlyMove:nil];
                break;
            case MGLayoutGridStyle:
                [self stackGridStyle:container onlyMove:nil];
                break;
        }

        // position attached and replacement boxes
        [MGLayoutManager positionAttachedBoxesIn:container];

        // zindex time
        [self stackByZIndexIn:container];
    }
}

+ (void)layoutBoxesIn:(UIView <MGLayoutBox> *)container duration:(NSTimeInterval)duration
      completion:(Block)completion {

  // layout locked?
  if (container.layingOut) {
    return;
  }
  container.layingOut = YES;

    // box provider style layout
    if (container.boxProvider) {
        [self positionBoxesIn:container];
        [container.boxProvider updateDataKeys];
        [container.boxProvider updateVisibleIndexes];
        [container.boxProvider updateVisibleBoxes];
        [self layoutVisibleBoxesIn:container duration:duration completion:completion];
        container.layingOut = NO;
        return;
    }

  // find new top boxes
  NSMutableOrderedSet *newTopBoxes = NSMutableOrderedSet.orderedSet;
  for (UIView <MGLayoutBox> *box in container.boxes) {
    if (box.boxLayoutMode != MGBoxLayoutAutomatic) {
      continue;
    }

    // found the first existing box
    if ([container.subviews containsObject:box] || box.replacementFor) {
      break;
    }

    [newTopBoxes addObject:box];
  }

  // find gone boxes
  NSArray *gone = [MGLayoutManager findBoxesInView:container
      notInSet:container.boxes];

  // every box is new and haven't asked for slide-in-from-empty animation?
  if (newTopBoxes.count == container.boxes.count
      && !container.slideBoxesInFromEmpty) {
    [newTopBoxes removeAllObjects];
  }

  // parent box relationship
  for (UIView <MGLayoutBox> *box in container.boxes) {
    box.parentBox = container;
  }

  // children layout first
  if (!container.dontLayoutChildren) {
    for (id <MGLayoutBox> box in container.boxes) {
      [box layout];
    }
  }

  // set origin for new top boxes
  CGFloat offsetY = 0;
  for (UIView <MGLayoutBox> *box in newTopBoxes) {
    box.x = container.leftPadding + box.leftMargin;
    offsetY += box.topMargin;
    box.y = offsetY;
    offsetY += box.height + box.bottomMargin;
  }

  // move top new boxes above the top
  for (UIView <MGLayoutBox> *box in newTopBoxes) {
    box.y -= offsetY;
  }

  // new boxes start faded out
  NSMutableSet *newNotTopBoxes = NSMutableSet.set;
  for (UIView <MGLayoutBox> *box in container.boxes) {
    if (![container.subviews containsObject:box] && !box.replacementFor) {
      box.alpha = 0;

      // collect new boxes that aren't top boxes
      if (![newTopBoxes containsObject:box]) {
        [newNotTopBoxes addObject:box];
      }
    }
  }

  // set start positions for remaining new boxes
  switch (container.contentLayoutMode) {
    case MGLayoutTableStyle:
      [MGLayoutManager stackTableStyle:container onlyMove:newNotTopBoxes];
      break;
    case MGLayoutGridStyle:
      [MGLayoutManager stackGridStyle:container onlyMove:newNotTopBoxes];
      break;
  }

  // everyone in now please
  for (UIView <MGLayoutBox> *box in container.boxes) {
    [container addSubview:box];
  }

  // pre animation positions for attached and replacement boxes
  [MGLayoutManager positionAttachedBoxesIn:container];

  // stack by zindex
  [MGLayoutManager stackByZIndexIn:container];

  // animate all to final pos and alpha
  [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{

    // gone boxes fade out
    for (UIView <MGLayoutBox> *box in gone) {
      box.alpha = 0;
    }

    // new boxes fade in
    for (UIView <MGLayoutBox> *box in container.boxes) {
      if (![gone containsObject:box] && !box.alpha) {
        box.alpha = 1;
      }
    }

    // set final positions
    [MGLayoutManager positionBoxesIn:container];

    // release the layout lock
    container.layingOut = NO;

  } completion:^(BOOL done) {

    // clean up
    for (UIView <MGLayoutBox> *goner in gone) {
      if (goner.superview == container && ![container.boxes containsObject:goner]) {
        [goner removeFromSuperview];
      }
    }

    // completion handler
    if (completion) {
      completion();
    }
  }];
}

#pragma mark - Layout strategies

+ (void)stackGridStyle:(UIView <MGLayoutBox> *)container {
    CGFloat x = container.leftPadding, y = container.topPadding, maxHeight = 0;
    for (int i = 0; i < container.boxProvider.count; i++) {
        CGSize size = [container.boxProvider sizeForBoxAtIndex:i];

        // next row?
        if (x + size.width > container.width) {
            x = container.leftPadding, y = maxHeight;
        }

        // calc position
        CGPoint origin = (CGPoint){roundToPixel(x), roundToPixel(y)};
        x += size.width, maxHeight = MAX(maxHeight, origin.y + size.height);
        container.boxProvider.boxPositions[i] = [NSValue valueWithCGPoint:origin];
    }
    [self prunePositionsFor:container];
}

+ (void)stackTableStyle:(UIView <MGLayoutBox> *)container {
    CGFloat y = container.topPadding;
    for (int i = 0; i < container.boxProvider.count; i++) {
        CGSize size = [container.boxProvider sizeForBoxAtIndex:i];
        CGPoint origin = (CGPoint){container.leftPadding, y};
        container.boxProvider.boxPositions[i] = [NSValue valueWithCGPoint:origin];
        y += size.height;
    }
    [self prunePositionsFor:container];
}

+ (void)prunePositionsFor:(UIView <MGLayoutBox> *)container {
    NSUInteger trueCount = container.boxProvider.count;
    if (container.boxProvider.boxPositions.count > trueCount) {
        NSUInteger excess = container.boxProvider.boxPositions.count - trueCount;
        NSIndexSet *indexes = [[NSIndexSet alloc] initWithIndexesInRange:NSMakeRange(
              container.boxProvider.boxPositions.count - excess, excess)];
        [container.boxProvider.boxPositions removeObjectsAtIndexes:indexes];
    }
}

+ (void)stackTableStyle:(UIView <MGLayoutBox> *)container
               onlyMove:(NSSet *)only {
  CGFloat y = container.topPadding, maxWidth = 0;

  // lay out automatic boxes
  for (UIView <MGLayoutBox> *box in container.boxes) {
    if (box.boxLayoutMode != MGBoxLayoutAutomatic) {
      continue;
    }
    maxWidth = MAX(maxWidth, box.leftMargin + box.width + box.rightMargin);
    y += box.topMargin;
    if (!only || [only containsObject:box]) {
      CGPoint newOrigin = CGPointMake(container.leftPadding + box.leftMargin,
          roundToPixel(y));
      if (!CGPointEqualToPoint(newOrigin, box.origin)) {
        box.origin = newOrigin;
      }
    }
    y += box.height + box.bottomMargin;
  }

  // don't update height if we weren't positioning everyone
  if (only) {
    return;
  }

    [self updateContentSizeFor:container];
}

+ (void)stackGridStyle:(UIView <MGLayoutBox> *)container
              onlyMove:(NSSet *)only {
  CGFloat x = container.leftPadding, y = container.topPadding, maxHeight = 0;

  // lay out automatic boxes
  for (UIView <MGLayoutBox> *box in container.boxes) {
    if (box.boxLayoutMode != MGBoxLayoutAutomatic) {
      continue;
    }

    // next row?
    if (x + box.leftMargin + box.width + box.rightMargin > container.width) {
      x = container.leftPadding;
      y = maxHeight;
    }

    // position
    x += box.leftMargin;
    if (!only || [only containsObject:box]) {
      box.origin = CGPointMake(roundToPixel(x), roundToPixel(y + box.topMargin));
    }

    x += box.width + box.rightMargin;
    maxHeight = MAX(maxHeight, y + box.topMargin + box.height + box.bottomMargin);
  }

  // don't update size if we weren't positioning everyone
  if (only) {
    return;
  }

    [self updateContentSizeFor:container];
}

+ (void)positionAttachedBoxesIn:(UIView <MGLayoutBox> *)container {
  for (UIView <MGLayoutBox> *box in container.boxes) {
    if (box.boxLayoutMode == MGBoxLayoutAttached) {
      box.origin = CGPointMake(box.attachedTo.frame.origin.x + box.leftMargin,
          box.attachedTo.frame.origin.y + box.topMargin);
    } else if (box.replacementFor) {
      box.origin = box.replacementFor.frame.origin;
      box.replacementFor = nil;
    }
  }
}

+ (NSArray *)findBoxesInView:(UIView *)view notInSet:(id)boxes {
  NSMutableArray *gone = @[].mutableCopy;

  // find gone boxes
  for (UIView <MGLayoutBox> *box in view.subviews) {

    // only manage MGLayoutBoxes
    if (![box conformsToProtocol:@protocol(MGLayoutBox)]) {
      continue;
    }

    if ([boxes indexOfObject:box] == NSNotFound) {
      [gone addObject:box];
    }
  }

  // find attached boxes that lost their buddy
  for (UIView <MGLayoutBox> *box in view.subviews) {

    // only looking for attached boxes
    if (![box conformsToProtocol:@protocol(MGLayoutBox)] || box.boxLayoutMode
        != MGBoxLayoutAttached) {
      continue;
    }

    // buddy is gone. *sob*
    if (!box.attachedTo || ![boxes containsObject:box.attachedTo]
        || [gone containsObject:box.attachedTo]) {
      [boxes removeObject:box];
      [gone addObject:box];
    }
  }

  return gone;
}

+ (NSSet *)findViewsInView:(UIView *)view notInSet:(id)boxes {
  NSMutableSet *gone = NSMutableSet.set;

  // find gone views
  for (UIView *item in view.subviews) {

    // ignore views tagged -2 and below
    if (item.tag < -1) {
      continue;
    }

    if (![boxes containsObject:item]) {
      [gone addObject:item];
    }
  }

  // find attached boxes that lost their buddy
  for (UIView <MGLayoutBox> *box in view.subviews) {

    // only looking for attached boxes
    if (![box conformsToProtocol:@protocol(MGLayoutBox)] || box.boxLayoutMode
        != MGBoxLayoutAttached) {
      continue;
    }

    // buddy is gone. *sob*
    if (!box.attachedTo || ![boxes containsObject:box.attachedTo]
        || [gone containsObject:box.attachedTo]) {
      [boxes removeObject:box];
      [gone addObject:box];
    }
  }

  return gone;
}

+ (void)updateContentSizeFor:(UIView <MGLayoutBox> *)container {
    CGSize newSize, oldSize = [container isKindOfClass:MGScrollView.class]
          ? [(id)container contentSize]
          : container.size;
    if (container.sizingMode == MGResizingShrinkWrap) {
        newSize = (CGSize){
              container.leftPadding + container.rightPadding,
              container.topPadding + container.bottomPadding
        };
    } else {
        newSize = oldSize;
    }

    if (container.boxProvider) {
        for (int i = 0; i < container.boxProvider.count; i++) {
            CGRect footprint = [container.boxProvider footprintForBoxAtIndex:i];
            newSize.width = MAX(newSize.width, CGRectGetMaxX(footprint));
            newSize.height = MAX(newSize.height, CGRectGetMaxY(footprint));
        }

    } else {
        for (UIView <MGLayoutBox> *box in container.boxes) {
            newSize.width = MAX(newSize.width, box.right + box.rightMargin + container.rightPadding);
            newSize.height = MAX(newSize.height, box.bottom + box.bottomMargin + container.bottomPadding);
        }
    }

    // only update size if it's changed
    if (!CGSizeEqualToSize(newSize, oldSize)) {
        if ([container isKindOfClass:MGScrollView.class]) {
            [(id)container setContentSize:newSize];
        } else {
            container.size = newSize;
        }
    }
}

+ (void)stackByZIndexIn:(UIView *)container {
  NSArray *sorted =
      [container.subviews sortedArrayUsingComparator:^NSComparisonResult(id<MGLayoutBox> view1,
          id<MGLayoutBox> view2) {
        int z1 = [view1 respondsToSelector:@selector(zIndex)] ? [view1 zIndex] : 0;
        int z2 = [view2 respondsToSelector:@selector(zIndex)] ? [view2 zIndex] : 0;
        if (z1 > z2) {
          return NSOrderedDescending;
        }
        if (z1 < z2) {
          return NSOrderedAscending;
        }
        return NSOrderedSame;
      }];

  for (UIView *view in sorted) {
    int sortedIndex = (int)[sorted indexOfObject:view];
    if (sortedIndex != [container.subviews indexOfObject:view]) {
      [container insertSubview:view atIndex:sortedIndex];
    }
  }
}

@end
