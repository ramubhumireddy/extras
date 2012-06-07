// Generated by CoffeeScript 1.3.3
(function() {
  var __hasProp = {}.hasOwnProperty,
    __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

  module.exports = function(BasePlugin) {
    var TextPlugin;
    return TextPlugin = (function(_super) {

      __extends(TextPlugin, _super);

      function TextPlugin() {
        return TextPlugin.__super__.constructor.apply(this, arguments);
      }

      TextPlugin.prototype.name = 'text';

      TextPlugin.prototype.getText = function(source, store) {
        var key, result;
        key = 'store.' + source.replace(/[#\{\(\n]/g, '').trim();
        try {
          result = eval(key);
        } catch (err) {
          result = source;
        }
        return result;
      };

      TextPlugin.prototype.populateText = function(source, store) {
        var me, result;
        me = this;
        result = source.replace(/\<t(ext)?\>([^\<]+)\<\/t(ext)?\>/g, function(str, group1, key, group3) {
          var value;
          value = me.getText(key, store);
          if (value !== key) {
            value = me.populateText(value, store);
          }
          return value;
        });
        return result;
      };

      TextPlugin.prototype.renderDocument = function(opts, next) {
        var file, me, templateData;
        me = this;
        templateData = opts.templateData, file = opts.file;
        if (file.isText()) {
          opts.content = me.populateText(opts.content, templateData);
          return next();
        } else {
          return next();
        }
      };

      return TextPlugin;

    })(BasePlugin);
  };

}).call(this);