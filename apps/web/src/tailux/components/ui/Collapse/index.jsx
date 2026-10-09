/* eslint-disable react-hooks/refs */
// Import Dependencies
import { forwardRef } from "react";

// Local Imports
import { useCollapse } from "@tailux/hooks";
import { Box } from "@tailux/components/ui";

// ----------------------------------------------------------------------

const Collapse = forwardRef((props, ref) => {
  const {
    children,
    in: opened,
    transitionDuration,
    transitionTimingFunction,
    min,
    style,
    onTransitionEnd,
    ...rest
  } = props;
  
  const getCollapseProps = useCollapse({
    opened,
    transitionDuration,
    transitionTimingFunction,
    min,
    onTransitionEnd,
  });

  if (transitionDuration === 0) {
    return opened ? <Box {...rest}>{children}</Box> : null;
  }

  return <Box {...getCollapseProps({ style, ref, ...rest })}>{children}</Box>;
});

Collapse.displayName = "Collapse";


export { Collapse };
