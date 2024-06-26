function(newDoc, oldDoc, userCtx, secObj) {
  /*
    LOCAL DOCUMENT VALIDATION

    This is for validating document structure, irrespective of authority, so it
    can be run both on couchdb and pouchdb (where you are technically admin).

    For validations around authority check lib/validate_doc_update.js, which is
    only run on the server.
  */

  var _err = function(msg) {
    throw({ forbidden: msg });
  };

  var hasRole = function(roles, role) {
    if (roles) {
      for (var i = 0; i < roles.length; i++) {
        if (roles[i] === role) {
          return true;
        }
      }
    }
    return false;
  };

  var isDbAdmin = function(userCtx, secObj) {
    if (hasRole(userCtx.roles, '_admin')) {
      return true;
    }

    if (secObj.admins && secObj.admins.names && secObj.admins.names.indexOf(userCtx.name) !== -1) {
      return true;
    }

    if (secObj.admins && secObj.admins.roles) {
      for (var i = 0; i < userCtx.roles.length; i++) {
        if (hasRole(secObj.admins.roles, userCtx.roles[i])) {
          return true;
        }
      }
    }

    return false;
  };

  /**
   * Ensure that type='form' documents are created with correctly formatted _id
   * property.
   */
  var validateForm = function() {
    var id_parts = newDoc._id.split(':');
    var prefix = id_parts[0];
    var form_id = id_parts.slice(1).join(':');
    if (prefix !== 'form') {
      _err('_id property must be prefixed with "form:". e.g. "form:registration"');
    }
    if (!form_id) {
      _err('_id property must define a value after "form:". e.g. "form:registration"');
    }
    if (newDoc._id !== newDoc._id.toLowerCase()) {
      _err('_id property must be lower case. e.g. "form:registration"');
    }
  };

  var validateUserSettings = function() {
    var id_parts = newDoc._id.split(':');
    var prefix = id_parts[0];
    var username = id_parts.slice(1).join(':');
    var idExample = ' e.g. "org.couchdb.user:sally"';
    if (prefix !== 'org.couchdb.user') {
      _err('_id must be prefixed with "org.couchdb.user:".' + idExample);
    }
    if (!username) {
      _err('_id must define a value after "org.couchdb.user:".' + idExample);
    }
    if (newDoc._id !== newDoc._id.toLowerCase()) {
      _err('_id must be lower case.' + idExample);
    }
    if (typeof newDoc.name === 'undefined' || newDoc.name !== username) {
      _err('name property must be equivalent to username.' + idExample);
    }
    if (newDoc.name.toLowerCase() !== username.toLowerCase()) {
      _err('name must be equivalent to username');
    }
    if (typeof newDoc.known !== 'undefined' && typeof newDoc.known !== 'boolean') {
      _err('known is not a boolean.');
    }
    if (typeof newDoc.roles !== 'object') {
      _err('roles is a required array');
    }
  };

  var authorizeUserSettings = function() {
    if (!oldDoc) {
      _err('You are not authorized to create user-settings');
    }
    if (typeof oldDoc.roles !== 'object') {
      _err('You are not authorized to edit roles');
    }
    if (newDoc.roles.length !== oldDoc.roles.length) {
      _err('You are not authorized to edit roles');
    }
    for (var i = 0; i < oldDoc.roles.length; i++) {
      if (oldDoc.roles[i] !== newDoc.roles[i]) {
        _err('You are not authorized to edit roles');
      }
    }
  }

  // admins can do anything
  if (isDbAdmin(userCtx, secObj)) {
    return;
  }
  if (userCtx.facility_id === newDoc._id) {
    _err('You are not authorized to edit your own place');
  }
  if (newDoc.type === 'form') {
    validateForm();
  }
  if (newDoc.type === 'user-settings') {
    validateUserSettings();
    authorizeUserSettings();
  }

  log(
    'medic-client validate_doc_update passed for User "' + userCtx.name +
    '" changing document "' +  newDoc._id + '"'
  );
}
