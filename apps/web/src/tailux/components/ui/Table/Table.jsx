// Import Dependencies
import { forwardRef } from "react";
import clsx from "clsx";

// ----------------------------------------------------------------------

const Table = forwardRef((props, ref) => {
  const {
    children,
    component,
    className,
    hoverable,
    zebra,
    dense,
    sticky,
    ...rest
  } = props;

  const Component = component || "table";
  return (
    <Component
      className={clsx(
        "table",
        hoverable && "is-hoverable",
        zebra && "is-zebra",
        dense && "is-dense",
        sticky && "is-sticky",
        className,
      )}
      ref={ref}
      {...rest}
    >
      {children}
    </Component>
  );
});

Table.displayName = "Table";


export { Table };
