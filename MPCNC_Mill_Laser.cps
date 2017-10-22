/**
  Copyright (C) 2017 by NtaajVaaj.
  All rights reserved.

  MPCNC Mill Laser post processor configuration.

  $Revision: 10000 $
  $Date: 2014-12-22 13:06:03 +0100 (ma, 22 dec 2014) $
  
  MPCNC posts processor for milling and laser/plasma cutting.

  Some design points:
  - Setup operation types: Milling, Water/Laser/Plasma
  - Only support MM units (inches may work with custom start gcode - NOT TESTED)
  - XY and Z independent travel speeds. Rapids are done with G1.
  - Arcs support on XY plane
  - Tested in Marlin 1.1.0RC8
  - Tested with LCD display and SD card (built in tool change require printing from SD and LCD to restart)
  - Support for 3 different laser power using "cutting modes" (through, etch, vaporize)

  ASSUMES: 
  - HOME position is not (0,0,0)
  - Fan is installed on Ramps' D8 connector
  - Fan is enabled at start of operation, and stopped at end of operation
*/

// Adapted from ”Grbl" Autodesk post
description = "DV MPCNC MILL";
vendor = "DV MPCNC";
vendorUrl = "N/A";
legal = "Copyright (C) 2017 by NtaajVaaj";
certificationLevel = 2;
minimumRevision = 24000;

longDescription = "Generic milling post for MPCNC";
extension = "gcode";
setCodePage("ascii");

capabilities = CAPABILITY_MILLING;
tolerance = spatial(0.002, MM);

// Arc support variables
minimumChordLength	=	spatial(0.01,	MM);
minimumCircularRadius	=	spatial(0.01,	MM);
maximumCircularRadius	=	spatial(1000,	MM);
minimumCircularSweep	=	toRad(0.01);
maximumCircularSweep	=	toRad(180);
allowHelicalMoves	=	false;
allowedCircularPlanes	=	undefined;
// user-defined properties
properties = {
  writeMachine: true, // write machine
  writeTools: true, // writes the tools
  useG28: true, // disable to avoid G28 output for safe machine retracts - when disabled you must manually ensure safe retracts
  showSequenceNumbers: false, // show sequence numbers
  sequenceNumberStart: 10, // first sequence number
  sequenceNumberIncrement: 1, // increment for sequence numbers
  separateWordsWithSpace: true, // specifies that the words should be separated with a white space

  cutterOnThrough: "M106 S200",     // GCode command to turn on the laser/plasma cutter in through mode
  cutterOnEtch: "M106 S100",        // GCode command to turn on the laser/plasma cutter in etch mode
  cutterOnVaporize: "M106 S255",    // GCode command to turn on the laser/plasma cutter in vaporize mode
  cutterOff: "M107",                // Gcode command to turn off the laser/plasma cutter
  travelSpeedXY: 2500,              // High speed for travel movements X & Y (mm/min)
  travelSpeedZ: 300,                // High speed for travel movements Z (mm/min)
  setOriginOnStart: false,          // Set origin when gcode start (G92)
  goOriginOnFinish: false,          // Go X0 Y0 Z0 at gcode end.  WILL BE OVERRIDEN BY goHomeOnFinish 
  goHomeOnFinish: true,				// Go HOME at gcode end.  Overrides goOriginOnFinish
  turnOffMotorsOnFinish: true,		// Turn off the steppers at gcode end.  MAKE SURE YOUR Z-AXIS DOESN'T 
  									//   FALL UNDER NO POWER
  toolChangeEnabled: true,          // Enable tool change code (bultin tool change requires LCD display)
  toolChangeXY: "X0 Y0",            // X&Y position for builtin tool change
  toolChangeZ: "Z200",              // Z position for builtin tool change, should be some big number.
  toolChangeZProbe: true,           // Z probe after tool change
  probeOnStart: true                // Execute probe gcode to align tool
};

// user-defined property definitions
propertyDefinitions = {
  writeMachine: {title:"Write machine", description:"Output the machine settings in the header of the code.", group:0, type:"boolean"},
  writeTools: {title:"Write tool list", description:"Output a tool list in the header of the code.", group:0, type:"boolean"},
  useG28: {title:"G28 Safe retracts", description:"Disable to avoid G28 output for safe machine retracts. When disabled, you must manually ensure safe retracts.", type:"boolean"},
  showSequenceNumbers: {title:"Use sequence numbers", description:"Use sequence numbers for each block of outputted code.", group:1, type:"boolean"},
  sequenceNumberStart: {title:"Start sequence number", description:"The number at which to start the sequence numbers.", group:1, type:"integer"},
  sequenceNumberIncrement: {title:"Sequence number increment", description:"The amount by which the sequence number is incremented by in each block.", group:1, type:"integer"},
  separateWordsWithSpace: {title:"Separate words with space", description:"Adds spaces between words if 'yes' is selected.", type:"boolean"}
};

var mapCoolantTable = new Table(
  [9, 8],
  {initial:COOLANT_OFF, force:true},
  "Invalid coolant mode"
);
var numberOfToolSlots = 9999;
var gFormat = createFormat({prefix:"G", decimals:0});
var mFormat = createFormat({prefix:"M", decimals:0});
var xyzFormat = createFormat({decimals:3});
var feedFormat = createFormat({decimals:0});
var toolFormat = createFormat({decimals:0});
var rpmFormat = createFormat({decimals:0});
var secFormat = createFormat({decimals:3, forceDecimal:true}); // seconds - range 0.001-1000
var taperFormat = createFormat({decimals:1, scale:DEG});

// Linear outputs
var xOutput = createVariable({prefix:" X"}, xyzFormat);
var yOutput = createVariable({prefix:" Y"}, xyzFormat);
var zOutput = createVariable({prefix:" Z"}, xyzFormat);
var fOutput = createVariable({prefix:" F"}, feedFormat);
var sOutput = createVariable({prefix:"S", force:true}, rpmFormat);

// circular output
var	iOutput	=	createReferenceVariable({prefix:" I"},	xyzFormat);
var	jOutput	=	createReferenceVariable({prefix:" J"},	xyzFormat);
var	kOutput	=	createReferenceVariable({prefix:" K"},	xyzFormat);

var gMotionModal = createModal({}, gFormat); // modal group 1 // G0-G3, ...
var gPlaneModal = createModal({onchange:function () {gMotionModal.reset();}}, gFormat); // modal group 2 // G17-19
var gAbsIncModal = createModal({}, gFormat); // modal group 3 // G90-91
var gFeedModeModal = createModal({}, gFormat); // modal group 5 // G93-94
var gUnitModal = createModal({}, gFormat); // modal group 6 // G20-21


// Misc variables
var WARNING_WORK_OFFSET = 0;
var powerState = false;
var cutterOn;
// collected state
var sequenceNumber;
var currentWorkOffset;


/**
  Writes the specified block.
*/
function writeBlock() {
  if (properties.showSequenceNumbers) {
    writeWords2("N" + sequenceNumber, arguments);
    sequenceNumber += properties.sequenceNumberIncrement;
  } else {
    writeWords(arguments);
  }
}

function formatComment(text) {
  return ";" + String(text).replace(/[\(\)]/g, "");
}

/**
  Output a comment.
*/
function writeComment(text) {
  writeln(formatComment(text));	
}

// Called in every new gcode file
function onOpen() {
  if (!properties.separateWordsWithSpace) {
    setWordSeparator("");
  }
  
  sequenceNumber = properties.sequenceNumberStart;
  writeln("%");

  if (programName) {
    writeComment(programName);
  }
  if (programComment) {
    writeComment(programComment);
  }
  
  // dump machine configuration
  var vendor = machineConfiguration.getVendor();
  var model = machineConfiguration.getModel();
  var description = machineConfiguration.getDescription();

  if (properties.writeMachine && (vendor || model || description)) {
    writeComment(localize("Machine"));
    if (vendor) {
      writeComment("  " + localize("vendor") + ": " + vendor);
    }
    if (model) {
      writeComment("  " + localize("model") + ": " + model);
    }
    if (description) {
      writeComment("  " + localize("description") + ": "  + description);
    }
  }

  // dump tool information
  if (properties.writeTools) {
    var zRanges = {};
    if (is3D()) {
      var numberOfSections = getNumberOfSections();
      for (var i = 0; i < numberOfSections; ++i) {
        var section = getSection(i);
        var zRange = section.getGlobalZRange();
        var tool = section.getTool();
        if (zRanges[tool.number]) {
          zRanges[tool.number].expandToRange(zRange);
        } else {
          zRanges[tool.number] = zRange;
        }
      }
    }
    
    var tools = getToolTable();
    if (tools.getNumberOfTools() > 0) {
      for (var i = 0; i < tools.getNumberOfTools(); ++i) {
        var tool = tools.getTool(i);
        var comment = "T" + toolFormat.format(tool.number) + "  " +
          "D=" + xyzFormat.format(tool.diameter) + " " +
          localize("CR") + "=" + xyzFormat.format(tool.cornerRadius);
        if ((tool.taperAngle > 0) && (tool.taperAngle < Math.PI)) {
          comment += " " + localize("TAPER") + "=" + taperFormat.format(tool.taperAngle) + localize("deg");
        }
        if (zRanges[tool.number]) {
          comment += " - " + localize("ZMIN") + "=" + xyzFormat.format(zRanges[tool.number].getMinimum());
        }
        comment += " - " + getToolTypeName(tool.type);
        writeComment(comment);
      }
    }
  }
 
  return;
}


// Called in every section
function onSection() {
  writeln("\n");

  // Tool change
  if(properties.toolChangeEnabled && !isFirstSection() && tool.number != getPreviousSection().getTool().number) {
    toolChange();
  }
  
  if( isFirstSection() ) {
    writeComment("Homing and Initial Conditions");  
    writeBlock("G90"); // Set to Absolute Positioning
    writeBlock("G21"); // Set Units to Millimeters
    writeBlock("M84 S0"); // Disable steppers timeout
    if(properties.setOriginOnStart) {
      writeBlock("G92 X0 Y0 Z0"); // Set origin to initial position
    } 
    writeBlock("M106 255");  // turn ON Controller Fan  
    writeln("\n");
  }
  
  // Machining type
  if(currentSection.type == TYPE_MILLING) {
    // Specific milling code
    writeComment(sectionComment + " - Milling - Tool: " + tool.number + " - " + getToolTypeName(tool.type));
  }

  if(currentSection.type == TYPE_JET) {
    // Cutter mode used for different cutting power in PWM laser
      switch (currentSection.jetMode) {
      case JET_MODE_THROUGH:
        cutterOn = properties.cutterOnThrough;
        break;
      case JET_MODE_ETCHING:
        cutterOn = properties.cutterOnEtch;
        break;
      case JET_MODE_VAPORIZE:
        cutterOn = properties.cutterOnVaporize;
        break;
      default:
        error("Cutting mode is not supported.");
    }
    writeComment(sectionComment + " - Laser/Plasma - Cutting mode: " + getParameter("operation:cuttingMode"));
  }

  // Print min/max boundaries for each section
  vectorX = new Vector(1,0,0);
  vectorY = new Vector(0,1,0);
  writeComment("X Min: " + xyzFormat.format(currentSection.getGlobalRange(vectorX).getMinimum()) + " - X Max: " + xyzFormat.format(currentSection.getGlobalRange(vectorX).getMaximum()));
  writeComment("Y Min: " + xyzFormat.format(currentSection.getGlobalRange(vectorY).getMinimum()) + " - Y Max: " + xyzFormat.format(currentSection.getGlobalRange(vectorY).getMaximum()));
  writeComment("Z Min: " + xyzFormat.format(currentSection.getGlobalZRange().getMinimum()) + " - Z Max: " + xyzFormat.format(currentSection.getGlobalZRange().getMaximum()));

  // Display section name in LCD
  writeBlock("M400");
  writeBlock("M117 " + sectionComment);
  if(properties.probeOnStart && tool.number != 0) {
    probeTool();
  }
  
  return;
}

// Feed movements
function onCircular(clockwise, cx, cy, cz, x,	y, z, feed)	{
  circularMovements(clockwise, cx, cy, cz, x,	y, z, feed);
  return;
}

// Called on waterjet/plasma/laser cuts
function onPower(power) {
  if(power != powerState) {
    if(power) {
      writeBlock(cutterOn);
    } else {
      writeBlock(properties.cutterOff);
    }
    powerState = power;
  }
  return;
}

// Called on Dwell Manual NC invocation
function onDwell(seconds) {
  writeComment("Dwell");
  writeBlock("G4 S" + seconds);
  writeBlock("");
}

// Called with every parameter in the documment/section
function onParameter(name, value) {

  // Write gcode initial info
  // Product version
  if(name == "generated-by") {
    writeComment(value);
    writeComment("Posts processor: " + FileSystem.getFilename(getConfigurationPath()));
  }
  // Date
  if(name == "generated-at") writeComment("Gcode generated: " + value + " GMT");
  // Document
  if(name == "document-path") writeComment("Document: " + value);
  // Setup
  if(name == "job-description") writeComment("Setup: " + value);

  // Get section comment
  if(name == "operation-comment") sectionComment = value;

  return;
}

function onSpindleSpeed(spindleSpeed) {
  writeBlock(sOutput.format(spindleSpeed));
}

// Rapid movements with G1 and differentiated travel speeds for XY and Z
function onRapid(_x, _y, _z) {
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);

  if(z) {
    f = fOutput.format(properties.travelSpeedZ);
    fOutput.reset();
    writeBlock("G1" + z + f);
  }
  if(x || y) {
    f = fOutput.format(properties.travelSpeedXY);
    fOutput.reset();
    writeBlock("G1" + x + y + f);
  }
  return;
}

// Linear movements
function onLinear(_x, _y, _z, _feed) {
  var x = xOutput.format(_x);
  var y = yOutput.format(_y);
  var z = zOutput.format(_z);
  var f = fOutput.format(_feed);
  if(x || y || z) {
    writeBlock("G1" + x + y + z + f);
  }
  return;
}

function onRapid5D(_x, _y, _z, _a, _b, _c) {
  error(localize("Multi-axis motion is not supported."));
}

function onLinear5D(_x, _y, _z, _a, _b, _c, feed) {
  error(localize("Multi-axis motion is not supported."));
}

// Circular movements
function circularMovements(_clockwise, _cx, _cy, _cz, _x, _y, _z, _feed) {
  // Marlin supports arcs only on XY plane
  switch (getCircularPlane()) {
  case PLANE_XY:
    var x = xOutput.format(_x);
    var y = yOutput.format(_y);
    var f = fOutput.format(_feed);
    var start	=	getCurrentPosition();
    var i = iOutput.format(_cx - start.x, 0);
    var j = jOutput.format(_cy - start.y, 0);

    if(_clockwise) {
      writeBlock("G2" + x + y + i + j + f);
    } else {
      writeBlock("G3" + x + y + i + j + f);
    }
    break;
  default:
    linearize(tolerance);
  }
  return;
}

// Tool change
function toolChange() {
  if(properties.gcodeToolFile == "") {
    // Builtin tool change gcode
    writeComment("Tool Change");

    // Beep
    writeBlock("M400"); // Wait movement buffer it's empty
    writeBlock("M300 S400 P2000");

    // Go to tool change position
    if(properties.toolChangeZ != "") {
      writeBlock("G1 " + properties.toolChangeZ + fOutput.format(properties.travelSpeedZ));
    }
    if(properties.toolChangeXY != "") {
      writeBlock("G1 " + properties.toolChangeXY + fOutput.format(properties.travelSpeedXY));
    }

    // Disable Z stepper
    writeBlock("M18 Z");

    // Ask tool change and wait user to touch lcd button
    writeBlock("M0 Put tool " + tool.number + " - " + getToolTypeName(tool.type));

    // Run Z probe gcode
    if(properties.toolChangeZProbe && tool.number != 0) {
      writeComment("Z Probe gcode goes here");
    }
    writeBlock("");
  } else {
    // Custom tool change gcode
    loadFile(properties.gcodeToolFile);
  }
}

// Called in every section end
function onSectionEnd() {
  xOutput.reset();
  yOutput.reset();
  zOutput.reset();
  fOutput.reset();
  writeBlock("");
  return;
}

// Called at end of gcode file
function onClose() {
  writeln("\n");

  writeComment("Job Complete.  Turn off steppers, fans, and go Home")
  // End message to LCD
  writeBlock("M107");  // turn OFF Controller Fan
  writeBlock("M400");
  writeBlock("M117 Job end");

    if(properties.goHomeOnFinish) {
      writeBlock("G28 Z"); 	// Home Z as to get it high enough clearance
      writeBlock("G28 X Y");  	// Home X and Y 
    }
    else if (properties.goOriginOnFinish) {
      writeBlock("G1 X0 Y0" + fOutput.format(properties.travelSpeedXY)); // Go to XY origin
      writeBlock("G1 Z0" + fOutput.format(properties.travelSpeedZ)); // Go to Z origin
    }
    
	if(properties.turnOffMotorsOnFinish)  {
    	writeBlock("M18"); // turn off motors to save power
   	}
  return;
}

// Probe tool
function probeTool() {
    writeComment("Probe tool - Not yet implemented");
    writeBlock("");
}

