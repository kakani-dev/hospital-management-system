
function ApplyWrapper({ when, wrapper, children }) {
    return when ? wrapper(children) : <>{children}</>;
}


export { ApplyWrapper }
