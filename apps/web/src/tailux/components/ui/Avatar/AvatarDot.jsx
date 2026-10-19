// Import Dependencies
import { forwardRef } from "react";
import clsx from "clsx";

// Local Imports
import { setThisClass } from "@tailux/utils/setThisClass";
import { COLORS } from "@tailux/constants/app.constant";

// ----------------------------------------------------------------------

const AvatarDot = forwardRef((props, ref) => {
  const { color = "neutral", isPing, className, children, ...rest } = props;

  return (
    <div
      className={clsx(
        "avatar-dot absolute rounded-full",
        color === "neutral"
          ? "bg-gray-300 dark:bg-dark-200"
          : [setThisClass(color), "bg-this dark:bg-this-light"],
        className,
      )}
      {...rest}
      ref={ref}
    >
      {isPing && (
        <span className="absolute inset-0 inline-flex h-full w-full animate-ping rounded-full bg-inherit opacity-80" />
      )}
      {children}
    </div>
  );
});

AvatarDot.displayName = "AvatarDot";


export { AvatarDot };
