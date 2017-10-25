import UIKit

public protocol UIComponentProtocol: class, UINodeDelegateProtocol {
  /// The component-tree context.
  weak var context: UIContextProtocol? { get }
  /// The view in which the component is going to be rendered.
  weak var canvasView: UIView? { get }
  /// Canvas bounding rect.
  var canvasSize: () -> CGSize { get set }
  /// Set the canvas view for this component.
  /// - parameter view: The view in which the component is going to be rendered.
  /// - parameter useBoundsAsCanvasSize: if 'true' the canvas size will return the view bounds.
  /// - parameter renderOnCanvasSizeChange: if 'true' the components will automatically
  /// trigger 'setNeedsRender' whenever the canvas view changes its bounds.
  func setCanvas(view: UIView, options: [UIComponentCanvasOption])
  /// Mark the component for rendering.
  func setNeedsRender(layoutAnimator: UIViewPropertyAnimator?)
  /// Trigger a render pass if the component was set dirty after 'suspendComponentRendering'
  /// has been invoked on the context.
  /// - note: In most scenarios you don't have to manually call this method - the context will
  /// automatically resume rendering on invalidated components when the suspension is terminated.
  func resumeFromSuspendedRenderingIfNecessary()
  /// Type-erased state associated to this component.
  /// - note: *Internal only.*
  var anyState: UIStateProtocol { get }
  /// Type-erased props associated to this component.
  /// - note: *Internal only.*
  var anyProps: UIPropsProtocol { get }
}

public enum UIComponentCanvasOption: Int {
  // The canvas size will return the view bounds.
  case useBoundsAsCanvasSize
  /// Triggers 'setNeedsRender' whenever the canvas view changes its bounds.
  case renderOnCanvasSizeChange
  /// If the component can overflow in the horizontal axis.
  case flexibleWidth
  /// If the component can overflow in the vertical axis.
  case flexibleHeight
  /// Default canvas option.
  public static func defaults() -> [UIComponentCanvasOption] {
    return [.useBoundsAsCanvasSize,
            .renderOnCanvasSizeChange,
            .flexibleHeight]
  }
}

// MARK: - UIComponent

open class UIComponent<S: UIStateProtocol, P: UIPropsProtocol>: NSObject, UIComponentProtocol {
  /// The root node (built as a result of the 'render' method).
  public var root: UINodeProtocol = UINilNode.nil {
    didSet {
      root.associatedComponent = self
      root.delegate = self
      setKey(node: root)
    }
  }
  /// The component parent (nil for root components).
  public weak var parent: UIComponentProtocol?
  /// The state associated with this component.
  /// A state is always associated to a unique component key and it's a unique instance living
  /// in the context identity map.
  public var state: S {
    get {
      let newInstance = S()
      if newInstance is UINilState {
        return UINilState.nil as! S
      }
      guard let key = key, !(newInstance is UINilState) else {
        fatalError("Key not defined for a non-nil state.")
      }
      guard let context = context else {
        fatalError("No context registered for this component.")
      }
      let currentState: S = context.pool.state(key: key)
      return currentState
    }
    set {
      guard let key = key else {
        fatalError("Attempting to access the state of a key-less component.")
      }
      context?.pool.store(key: key, state: state)
      setNeedsRender()
    }
  }
  /// Use props to pass data & event handlers down to your child components.
  public var props: P = P()
  public var anyProps: UIPropsProtocol { return props }
  public var anyState: UIStateProtocol { return state }
  /// A unique key for the component (necessary if the component is stateful).
  public let key: String?
  /// Forwards node layout method callbacks.
  public weak var delegate: UINodeDelegateProtocol?
  public weak var context: UIContextProtocol?
  public private(set) weak var canvasView: UIView? {
    didSet {
      assert(parent == nil, "Unable to set a canvas view on a non-root component.")
    }
  }
  public var canvasSize: () -> CGSize = {
    return CGSize(width: UIScreen.main.bounds.width, height: CGFloat.max)
  }
  private var boundsObserver: UIContextViewBoundsObserver? = nil
  private var setNeedsRenderCalledDuringSuspension: Bool = false

  required public init(context: UIContextProtocol, key: String? = nil) {
    assert(context._componentInitFromContext, "Explicit init call is prohibited.")
    self.key = key
    self.context = context
    super.init()
    hookInspectorIfAvailable()
  }

  public func setCanvas(view: UIView,
                        options: [UIComponentCanvasOption] = UIComponentCanvasOption.defaults()) {
    canvasView = view
    context?.canvasView = canvasView
    if options.contains(.useBoundsAsCanvasSize) {
      canvasSize = { [weak self] in
        var size = self?.canvasView?.bounds.size ?? CGSize.zero
        size.height = options.contains(.flexibleHeight) ? CGFloat.max : size.height
        size.width = options.contains(.flexibleWidth) ? CGFloat.max : size.width
        return size
      }
    }
    boundsObserver = nil
    if options.contains(.renderOnCanvasSizeChange) {
      boundsObserver = UIContextViewBoundsObserver(view: view) { [weak self] _ in
        self?.setNeedsRender()
      }
    }
  }

  public func setNeedsRender(layoutAnimator: UIViewPropertyAnimator? = nil) {
    assert(Thread.isMainThread)
    guard parent == nil else {
      parent?.setNeedsRender(layoutAnimator: layoutAnimator)
      return
    }
    guard let context = context, let view = canvasView else {
      fatalError("Attempting to render a component without a canvas view and/or a context.")
    }
    // Rendering is suspended for this context for the time being.
    // 'resumeFromSuspendedRenderingIfNecessary' will automatically be called when the render
    // context will be resumed.
    if context._isRenderSuspended {
      setNeedsRenderCalledDuringSuspension = true
      return
    }
    // *Optional* the property animator that is going to be used for frame changes in the component
    // subtree. This field is auotmatically reset to 'nil' at the end of every 'render' pass.
    if let layoutAnimator = layoutAnimator {
      context.layoutAnimator = layoutAnimator
    }
    root = render(context: context)
    root.reconcile(in: view, size: canvasSize(), options: [])

    context.didRenderRootComponent(self)

    context.pool.flushObsoleteStates(validKeys: root._retrieveKeysRecursively())
    inspectorMarkDirty()

    // Reset the animatable frame changes to default.
    context.layoutAnimator = nil
  }

  public func resumeFromSuspendedRenderingIfNecessary() {
    assert(Thread.isMainThread)
    guard setNeedsRenderCalledDuringSuspension else {
      return
    }
    setNeedsRenderCalledDuringSuspension = false
    setNeedsRender()
  }

  private func setKey(node: UINodeProtocol) {
    if let key = key {
      node.key = key
    }
    #if DEBUG
    node._debugPropsDescription = props.reflectionDescription(del: UINodeInspectorDefaultDelimiters)
    node._debugStateDescription = state.reflectionDescription(del: UINodeInspectorDefaultDelimiters)
    #endif
  }

  /// Returns the desired child key prefixed with the key of the father.
  public func childKey(_ postfix: String) -> String {
    return "\(key ?? "")-\(postfix)"
  }

  /// Builds the component node.
  /// - note: Use this function to insert the node as a child of a pre-existent node hierarchy.
  public func asNode() -> UINodeProtocol {
    guard let context = context else {
      fatalError("Attempting to render a component without a valid context.")
    }
    let node = render(context: context)
    self.root = node
    return node
  }

  /// Retrieves the component from the context for the key passed as argument.
  /// If no component is registered yet, a new one will be allocated and returned.
  /// - parameter type: The desired *UIComponent* subclass.
  /// - parameter key: The unique key ('nil' for a transient component).
  /// - parameter props: Configurations and callbacks passed down to the component.
  public func childComponent<S, P, C: UIComponent<S, P>>(_ type: C.Type,
                                                         key: String? = nil,
                                                         props: P = P()) -> C {
    guard let context = context else {
      fatalError("Attempting to create a component without a valid context.")
    }
    if let key = key {
      return context.component(type, key: key, props: props, parent: self)
    } else {
      return context.transientComponent(type, props: props, parent: self)
    }
  }

  /// Builds the node hierarchy for this component.
  /// The render() function should be pure, meaning that it does not modify component state,
  /// it returns the same result each time it’s invoked.
  /// - note: Subclasses *must* override this method.
  /// - parameter context: The component-tree context.
  open func render(context: UIContextProtocol) -> UINodeProtocol {
    return UINilNode.nil
  }

  open func nodeDidMount(_ node: UINodeProtocol, view: UIView) {
    delegate?.nodeDidMount(node, view: view)
  }

  open func nodeWillLayout(_ node: UINodeProtocol, view: UIView) {
    delegate?.nodeWillLayout(node, view: view)
  }

  open func nodeDidLayout(_ node: UINodeProtocol, view: UIView) {
    delegate?.nodeDidLayout(node, view: view)
  }
}

// MARK: - UIContextViewBoundsObserver

private final class UIContextViewBoundsObserver: NSObject {
  // The observed canvas view.
  private weak var view: UIView?
  // The callback that is going to be invoked whenever the observed view changes its bounds.
  private let callback: (CGSize) -> Void
  // KVO observation token.
  private var token: NSKeyValueObservation?
  // The last recorded size.
  private var size = CGSize.zero

  init(view: UIView, callback: @escaping (CGSize) -> Void) {
    self.view = view
    self.callback = callback
    super.init()
    self.token = view.observe(\UIView.bounds,
                              options: [.initial, .new, .old]) { [weak self] (view, change) in
      let oldSize = self?.size ?? CGSize.zero
      if view.bounds.size != oldSize {
        self?.size = view.bounds.size
        self?.callback(view.bounds.size)
      }
    }
  }
}
