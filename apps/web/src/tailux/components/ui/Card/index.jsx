// Import Dependencies
import { forwardRef } from "react";
import clsx from 'clsx'

// Local Imports
import { Box } from "@tailux/components/ui";
import { useThemeContext } from "@tailux/contexts/theme/context";

// -------------------------------------------------------------

const Card = forwardRef((props, ref) => {
  const { cardSkin } = useThemeContext();

  const { skin = cardSkin, children, className, ...rest } = props;

  return (
    <Box
      ref={ref}
      className={clsx(
        "card rounded-lg",
        skin &&
          skin !== "none" && [
            skin === "bordered" &&
              "border border-gray-200 dark:border-dark-600 print:border-0",
            skin === "shadow" &&
              "bg-white shadow-soft dark:bg-dark-700 dark:shadow-none print:shadow-none",
          ],
        className,
      )}
      {...rest}
    >
      {children}
    </Box>
  );
});

Card.displayName = "Card";


export { Card };
